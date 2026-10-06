//
//  FrameCapture.swift
//  LambdaVision
//
//  One-shot frame capture for the debug server's `screenshot` endpoint
//  (DebugEndpoints): what the player sees, as a PNG, without a cable or
//  `devicectl` (which can't capture a visionOS screen).
//
//  How a capture runs, so the render loop never waits for it:
//    1. The endpoint posts a request and awaits it (`capture`).
//    2. The render thread's next frame (Renderer.render, first drawable)
//       calls `encode`. With a request pending it appends one compute
//       encoder to the frame's command buffer, after a barrier on every
//       earlier stage (Metal 4 tracks no hazards), that copies the wanted
//       pixels into a fresh shared buffer. Without one it is a lock and a
//       timestamp.
//    3. When the GPU signals that frame's endFrameEvent value, a listener
//       on a utility queue decodes, unwarps, resizes and PNG-encodes
//       (FrameImage) and resumes the endpoint.
//    4. The next frame that uses the same residency set drops the buffer
//       from it again (residency sets are mutated on the render thread only).
//
//  Sources:
//    • composited (default): the drawable itself after every pass this app
//      encodes — the engine composite, arms, gun, body, HEV holograms, the
//      palm panel and weapon wheel. That is what the compositor is handed;
//      what it adds afterwards (system overlays, reprojection to display
//      time, lens warp) is not in it. The drawable is foveated: its
//      periphery is stored at reduced density, so the copy is unwarped
//      through the frame's rasterization rate map back to its logical size
//      (unwarp=false keeps the physical layout).
//    • engine: the engine's colour map alone, both eyes, as ANGLE drew it
//      (no Metal overlays, no foveation; GL rows flipped upright).
//

import CompositorServices
import Foundation
@preconcurrency import Metal
import QuartzCore
import os

nonisolated final class FrameCapture: @unchecked Sendable {
    static let shared = FrameCapture()

    nonisolated enum Eye: String, CaseIterable, Sendable { case left, right, both }
    nonisolated enum Source: String, CaseIterable, Sendable { case composited, engine }

    nonisolated struct Request: Sendable {
        var eye: Eye = .both
        var source: Source = .composited
        /// Cap on the PNG's width in pixels (both eyes together); 0 = native.
        var maxWidth: Int = 1600
        var unwarp = true
    }

    nonisolated enum Failure: Error, Sendable {
        case noFrames
        case timeout
        case unsupported(String)
        case encodeFailed
    }

    /// What the last capture read, for `state` and for anyone wondering why
    /// a picture looks the way it does.
    nonisolated struct Info: Sendable, Encodable {
        var source: String
        var pixelFormat: String
        var layout: String          // layered / dedicated (drawable), array (engine)
        var foveated: Bool
        var physicalWidth: Int      // one eye, as stored
        var physicalHeight: Int
        var logicalWidth: Int       // one eye, as seen (rate map screen size)
        var logicalHeight: Int
        var outputWidth: Int
        var outputHeight: Int
        var gpuToPngMs: Double
        var capturedAt: String
    }

    // MARK: State

    private final class Pending: @unchecked Sendable {
        let request: Request
        private var continuation: CheckedContinuation<Result<Data, Failure>, Never>?
        private let lock = NSLock()
        init(_ request: Request, _ continuation: CheckedContinuation<Result<Data, Failure>, Never>) {
            self.request = request
            self.continuation = continuation
        }
        func resume(_ result: Result<Data, Failure>) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: result)
        }
    }

    private struct State {
        var lastFrameAt: Double = 0
        var queue: [Pending] = []
        var retired: [(set: MTLResidencySet, buffer: MTLBuffer)] = []
        var info: Info?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let work: DispatchQueue
    private let listener: MTLSharedEventListener

    private init() {
        work = DispatchQueue(label: "LambdaVision.FrameCapture", qos: .utility)
        listener = MTLSharedEventListener(dispatchQueue: work)
    }

    var lastInfo: Info? { state.withLockUnchecked { $0.info } }

    /// Seconds since the render thread last drew a frame (nil: never).
    var secondsSinceLastFrame: Double? {
        let t = state.withLockUnchecked { $0.lastFrameAt }
        return t == 0 ? nil : CACurrentMediaTime() - t
    }

    // MARK: Endpoint side

    /// Captures the next rendered frame. Throws `.noFrames` at once when the
    /// renderer isn't drawing (immersive space closed or paused).
    func capture(_ request: Request, timeout: Duration = .seconds(5)) async throws(Failure) -> Data {
        guard let idle = secondsSinceLastFrame, idle < 1 else { throw .noFrames }
        let result: Result<Data, Failure> = await withCheckedContinuation { continuation in
            let pending = Pending(request, continuation)
            state.withLockUnchecked { $0.queue.append(pending) }
            Task.detached { [weak self] in
                try? await Task.sleep(for: timeout)
                // Only a request no frame has taken yet times out here; a
                // taken one is answered by its GPU completion.
                let stillQueued = self?.state.withLockUnchecked { s -> Bool in
                    guard let i = s.queue.firstIndex(where: { $0 === pending }) else { return false }
                    s.queue.remove(at: i)
                    return true
                } ?? true
                if stillQueued { pending.resume(.failure(.timeout)); return }
                // Taken, but the frame never completed (the space closed
                // mid-frame): don't leave the caller hanging. A no-op when
                // the completion already answered.
                try? await Task.sleep(for: .seconds(10))
                pending.resume(.failure(.timeout))
            }
        }
        return try result.get()
    }

    // MARK: Render-thread side

    /// Called once per frame from Renderer.render (first drawable), after
    /// everything else is encoded and before `endCommandBuffer`. `completion`
    /// / `value` is the endFrameEvent value this command buffer's frame
    /// signals; `residencySet` the frame's (already committed) set.
    func encode(commandBuffer: MTL4CommandBuffer, drawable: LayerRenderer.Drawable, colorMap: MTLTexture?,
                residencySet: MTLResidencySet, completion: MTLSharedEvent, value: UInt64) {
        let (pending, retired) = state.withLockUnchecked { s -> (Pending?, [MTLBuffer]) in
            s.lastFrameAt = CACurrentMediaTime()
            var mine: [MTLBuffer] = []
            s.retired.removeAll { entry in
                guard entry.set === residencySet else { return false }
                mine.append(entry.buffer)
                return true
            }
            return (s.queue.isEmpty ? nil : s.queue.removeFirst(), mine)
        }
        if !retired.isEmpty {
            for buffer in retired { residencySet.removeAllocation(buffer) }
            residencySet.commit()
        }
        guard let pending else { return }

        let plan: Plan
        switch Self.plan(pending.request, drawable: drawable, colorMap: colorMap) {
        case .success(let p): plan = p
        case .failure(let failure): pending.resume(.failure(failure)); return
        }
        guard let buffer = commandBuffer.device.makeBuffer(length: plan.totalBytes, options: .storageModeShared),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            pending.resume(.failure(.unsupported("could not allocate \(plan.totalBytes) bytes for the read-back")))
            return
        }
        buffer.label = "FrameCapture.readback"
        residencySet.addAllocation(buffer)
        residencySet.commit()
        encoder.label = "FrameCapture"
        // Everything this frame drew (render passes, MSAA resolve) lands
        // before the copy reads it.
        encoder.barrier(afterQueueStages: .all, beforeStages: .blit, visibilityOptions: .device)
        for eye in plan.eyes {
            encoder.copy(sourceTexture: eye.texture, sourceSlice: eye.slice, sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: eye.originX, y: eye.originY, z: 0),
                         sourceSize: MTLSize(width: eye.width, height: eye.height, depth: 1),
                         destinationBuffer: buffer, destinationOffset: eye.offset,
                         destinationBytesPerRow: eye.bytesPerRow, destinationBytesPerImage: eye.bytesPerRow * eye.height)
        }
        encoder.endEncoding()

        let started = CACurrentMediaTime()
        let readback = Readback(buffer: buffer, set: residencySet)
        completion.notify(listener, atValue: value) { [weak self] _, _ in
            // On `work`: the GPU is done with the frame.
            let result = Self.image(plan, buffer: readback.buffer)
            self?.state.withLockUnchecked { s in
                s.retired.append((readback.set, readback.buffer))
                if case .success(let made) = result {
                    s.info = Info(source: plan.request.source.rawValue, pixelFormat: plan.formatName, layout: plan.layoutName,
                                  foveated: plan.eyes.contains { $0.rateMap != nil },
                                  physicalWidth: plan.eyes[0].width, physicalHeight: plan.eyes[0].height,
                                  logicalWidth: plan.eyes[0].logicalWidth, logicalHeight: plan.eyes[0].logicalHeight,
                                  outputWidth: made.width, outputHeight: made.height,
                                  gpuToPngMs: (CACurrentMediaTime() - started) * 1000,
                                  capturedAt: ISO8601DateFormatter.string(from: Date(), timeZone: .gmt,
                                                                          formatOptions: [.withInternetDateTime, .withFractionalSeconds]))
                }
            }
            pending.resume(result.map(\.png))
        }
    }

    /// The read-back buffer and the residency set holding it, handed to the
    /// completion queue; the render thread touches neither again until the
    /// buffer is retired.
    private struct Readback: @unchecked Sendable {
        let buffer: MTLBuffer
        let set: MTLResidencySet
    }

    // MARK: Planning

    private struct EyeCopy: @unchecked Sendable {
        let texture: MTLTexture
        let slice: Int
        let originX: Int, originY: Int
        let width: Int, height: Int
        let offset: Int
        let bytesPerRow: Int
        // Composited only: the foveation map to unwarp through.
        let rateMap: MTLRasterizationRateMap?
        let rateLayer: Int
        let logicalWidth: Int, logicalHeight: Int
    }

    private struct Plan: @unchecked Sendable {
        let request: Request
        let layout: FrameImage.Layout
        let flip: Bool
        let eyes: [EyeCopy]          // in output order, left first
        let totalBytes: Int
        let formatName: String
        let layoutName: String
    }

    private static func plan(_ request: Request, drawable: LayerRenderer.Drawable,
                             colorMap: MTLTexture?) -> Result<Plan, Failure> {
        // The eyes ordered by where they sit (view order isn't guaranteed
        // to be left, right): leftmost first.
        let order = drawable.views.indices.sorted {
            drawable.views[$0].transform.columns.3.x < drawable.views[$1].transform.columns.3.x
        }
        let wanted: [Int]
        switch request.eye {
        case .left: wanted = Array(order.prefix(1))
        case .right: wanted = Array(order.suffix(1))
        case .both: wanted = order
        }

        var eyes: [EyeCopy] = []
        var offset = 0
        switch request.source {
        case .engine:
            guard let colorMap else { return .failure(.unsupported("the engine colour map is not allocated yet")) }
            guard let layout = layout(colorMap.pixelFormat) else {
                return .failure(.unsupported("engine colour format \(name(colorMap.pixelFormat))"))
            }
            for view in wanted {
                // colorMap slice = the eye index the engine rendered (view index).
                let slice = min(view, colorMap.arrayLength - 1)
                let bpr = colorMap.width * layout.bytesPerPixel
                eyes.append(EyeCopy(texture: colorMap, slice: slice, originX: 0, originY: 0,
                                    width: colorMap.width, height: colorMap.height, offset: offset, bytesPerRow: bpr,
                                    rateMap: nil, rateLayer: 0,
                                    logicalWidth: colorMap.width, logicalHeight: colorMap.height))
                offset += bpr * colorMap.height
            }
            return .success(Plan(request: request, layout: layout, flip: true, eyes: eyes, totalBytes: offset,
                                 formatName: name(colorMap.pixelFormat), layoutName: "array"))

        case .composited:
            let maps = drawable.rasterizationRateMaps
            var format: MTLPixelFormat = .invalid
            for view in wanted {
                let map = drawable.views[view].textureMap
                guard map.textureIndex < drawable.colorTextures.count else {
                    return .failure(.unsupported("view \(view) names colour texture \(map.textureIndex) of \(drawable.colorTextures.count)"))
                }
                let texture = drawable.colorTextures[map.textureIndex]
                format = texture.pixelFormat
                guard let layout = layout(format) else {
                    return .failure(.unsupported("drawable colour format \(name(format))"))
                }
                guard !texture.isFramebufferOnly, texture.storageMode != .memoryless else {
                    return .failure(.unsupported("the drawable's colour texture can't be read back (framebuffer-only)"))
                }
                let vp = map.viewport
                let x = max(0, Int(vp.originX)), y = max(0, Int(vp.originY))
                let w = min(Int(vp.width), texture.width - x), h = min(Int(vp.height), texture.height - y)
                guard w > 0, h > 0 else { return .failure(.unsupported("empty viewport for view \(view)")) }
                // One map per view (dedicated layout) or one map with a
                // layer per view (layered).
                var rateMap: MTLRasterizationRateMap?
                var layer = 0
                if maps.count == drawable.views.count, maps.count > 1 {
                    rateMap = maps[view]
                } else if let first = maps.first {
                    rateMap = first
                    layer = view < first.layerCount ? view : 0
                }
                var logical = (w, h)
                if let rateMap, request.unwarp { logical = (rateMap.screenSize.width, rateMap.screenSize.height) }
                let bpr = w * layout.bytesPerPixel
                eyes.append(EyeCopy(texture: texture, slice: map.sliceIndex, originX: x, originY: y,
                                    width: w, height: h, offset: offset, bytesPerRow: bpr,
                                    rateMap: request.unwarp ? rateMap : nil, rateLayer: layer,
                                    logicalWidth: logical.0, logicalHeight: logical.1))
                offset += bpr * h
            }
            guard let layout = layout(format) else { return .failure(.unsupported("no views")) }
            return .success(Plan(request: request, layout: layout, flip: false, eyes: eyes, totalBytes: offset,
                                 formatName: name(format),
                                 layoutName: drawable.colorTextures.count > 1 ? "dedicated" : "layered"))
        }
    }

    // MARK: Image (work queue)

    private static func image(_ plan: Plan, buffer: MTLBuffer) -> Result<(png: Data, width: Int, height: Int), Failure> {
        let raw = UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)
        // Per-eye output width: the cap is for the whole picture.
        let perEyeCap = plan.request.maxWidth > 0 ? max(1, plan.request.maxWidth / plan.eyes.count) : 0
        var planes: [FrameImage.Plane] = []
        for eye in plan.eyes {
            let slice = UnsafeRawBufferPointer(rebasing: raw[eye.offset..<(eye.offset + eye.bytesPerRow * eye.height)])
            var plane = FrameImage.decode(slice, width: eye.width, height: eye.height, bytesPerRow: eye.bytesPerRow,
                                          layout: plan.layout, flipVertically: plan.flip)
            let target = FrameImage.fitted(width: eye.logicalWidth, height: eye.logicalHeight, maxWidth: perEyeCap)
            if let rateMap = eye.rateMap {
                // Unwarp at up to twice the output size, then area-average
                // down: the foveal region is denser than the output.
                let inter = (min(eye.logicalWidth, target.width * 2), min(eye.logicalHeight, target.height * 2))
                let layer = eye.rateLayer
                let map = FrameImage.AxisMap.mapped(output: inter, screen: (eye.logicalWidth, eye.logicalHeight)) { x, y in
                    let p = rateMap.physicalCoordinates(screenCoordinates: MTLCoordinate2DMake(x, y), layer: layer)
                    return (p.x, p.y)
                }
                plane = FrameImage.remap(plane, map)
            }
            planes.append(FrameImage.resize(plane, width: target.width, height: target.height))
        }
        let picture = planes.count == 2 ? FrameImage.sideBySide(planes[0], planes[1]) : planes[0]
        guard let png = FrameImage.png(picture) else { return .failure(.encodeFailed) }
        return .success((png, picture.width, picture.height))
    }

    // MARK: Formats

    static func layout(_ format: MTLPixelFormat) -> FrameImage.Layout? {
        switch format {
        case .bgra8Unorm, .bgra8Unorm_srgb: .bgra8
        case .rgba8Unorm, .rgba8Unorm_srgb: .rgba8
        case .rgba16Unorm: .rgba16Unorm
        case .rgba16Float: .rgba16Float
        case .bgr10a2Unorm: .bgr10a2
        case .rgb10a2Unorm: .rgb10a2
        default: nil
        }
    }

    static func name(_ format: MTLPixelFormat) -> String {
        switch format {
        case .bgra8Unorm: "bgra8Unorm"
        case .bgra8Unorm_srgb: "bgra8Unorm_srgb"
        case .rgba8Unorm: "rgba8Unorm"
        case .rgba8Unorm_srgb: "rgba8Unorm_srgb"
        case .rgba16Unorm: "rgba16Unorm"
        case .rgba16Float: "rgba16Float"
        case .bgr10a2Unorm: "bgr10a2Unorm"
        case .rgb10a2Unorm: "rgb10a2Unorm"
        case .bgra10_xr: "bgra10_xr"
        case .bgra10_xr_srgb: "bgra10_xr_srgb"
        case .bgr10_xr: "bgr10_xr"
        case .bgr10_xr_srgb: "bgr10_xr_srgb"
        default: "MTLPixelFormat(\(format.rawValue))"
        }
    }
}
