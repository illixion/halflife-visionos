// Metal: a depth-stencil texture view OF a texture view misaddresses the stencil plane.
// Build and run:  swiftc -O repro.swift -o repro && ./repro      (headless; exit 1 if the bug appears)
//
// Root R = 2-slice 2D-array texture. V1 = 2D view of slice N of R. V2 = 2D view of V1 (slice 0).
// Every case clears both slices of R through R itself, draws a full-screen triangle into one
// slice (through V1 directly, or through V2), then reads BOTH slices back from R with a blit and
// counts pixels that differ from what that slice should hold.
import Metal
import Foundation

let dev = MTLCreateSystemDefaultDevice()!
let q = dev.makeCommandQueue()!
let W = 256, H = 256
let lib = try! dev.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
vertex float4 vs(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); return float4(p * 2.0 - 1.0, 0.25, 1.0); }
fragment float4 fs() { return float4(1, 0, 1, 1); }
""", options: nil)

enum Kind { case depthStencil, depthOnly, color }   // d32Float_s8 / depth32Float / rgba8Unorm
struct Case { let label: String; let kind: Kind; let nested: Bool; let slice: Int; let samples: Int }

// Pixel counts of each plane that differ from the expected value, for slices 0 and 1.
func wrong<T: Equatable>(_ b: MTLBuffer, _ type: T.Type, _ n: Int, _ want: [T]) -> Int {
    let p = b.contents().assumingMemoryBound(to: T.self)
    return (0..<n).filter { p[$0] != want[$0 % want.count] }.count
}

func run(_ c: Case) -> Bool {
    let fmt: MTLPixelFormat = c.kind == .color ? .rgba8Unorm : c.kind == .depthOnly ? .depth32Float : .depth32Float_stencil8
    let hasS = c.kind == .depthStencil
    let d = MTLTextureDescriptor()
    d.pixelFormat = fmt; d.width = W; d.height = H; d.textureType = .type2DArray; d.arrayLength = 2
    d.usage = [.renderTarget, .shaderRead, .pixelFormatView]; d.storageMode = .private
    let root = dev.makeTexture(descriptor: d)!
    func sliceView(_ t: MTLTexture, _ s: Int) -> MTLTexture {
        t.makeTextureView(pixelFormat: fmt, textureType: .type2D, levels: 0..<1, slices: s..<(s + 1))!
    }
    func attach(_ p: MTLRenderPassDescriptor, _ t: MTLTexture, slice: Int = 0, resolve: MTLTexture? = nil, store: MTLStoreAction) {
        if c.kind == .color {
            let a = p.colorAttachments[0]!; a.texture = t; a.slice = slice; a.resolveTexture = resolve
            a.loadAction = .clear; a.clearColor = MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1); a.storeAction = store
        } else {
            let a = p.depthAttachment!; a.texture = t; a.slice = slice; a.resolveTexture = resolve
            a.loadAction = .clear; a.clearDepth = 0.5; a.storeAction = store
            if hasS {
                let s = p.stencilAttachment!; s.texture = t; s.slice = slice; s.resolveTexture = resolve
                s.loadAction = .clear; s.clearStencil = 3; s.storeAction = store
            }
        }
    }
    let cb = q.makeCommandBuffer()!
    for s in 0..<2 {   // known contents in both slices, written through the root only
        let p = MTLRenderPassDescriptor(); attach(p, root, slice: s, store: .store)
        cb.makeRenderCommandEncoder(descriptor: p)!.endEncoding()
    }
    let v1 = sliceView(root, c.slice)
    let target = c.nested ? sliceView(v1, 0) : v1
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = lib.makeFunction(name: "vs"); pd.rasterSampleCount = c.samples
    if c.kind == .color { pd.fragmentFunction = lib.makeFunction(name: "fs"); pd.colorAttachments[0].pixelFormat = fmt }
    else { pd.depthAttachmentPixelFormat = fmt; if hasS { pd.stencilAttachmentPixelFormat = fmt } }
    let pass = MTLRenderPassDescriptor()
    if c.samples > 1 {
        let m = MTLTextureDescriptor()
        m.textureType = .type2DMultisample; m.pixelFormat = fmt; m.width = W; m.height = H
        m.sampleCount = c.samples; m.usage = [.renderTarget]; m.storageMode = .private
        attach(pass, dev.makeTexture(descriptor: m)!, resolve: target, store: .multisampleResolve)
    } else { attach(pass, target, store: .store) }
    let dd = MTLDepthStencilDescriptor()
    dd.depthCompareFunction = .always; dd.isDepthWriteEnabled = true
    let sd = MTLStencilDescriptor(); sd.stencilCompareFunction = .always; sd.depthStencilPassOperation = .replace
    if hasS { dd.frontFaceStencil = sd; dd.backFaceStencil = sd }
    let e = cb.makeRenderCommandEncoder(descriptor: pass)!
    e.setRenderPipelineState(try! dev.makeRenderPipelineState(descriptor: pd))
    if c.kind != .color { e.setDepthStencilState(dev.makeDepthStencilState(descriptor: dd)!); e.setStencilReferenceValue(17) }
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()

    // Read back every plane of both slices of the ROOT (what any other consumer would see), and, as a
    // self-check, the written slice through `target` itself (what the producer would see).
    func buf(_ bytes: Int) -> MTLBuffer { dev.makeBuffer(length: bytes, options: .storageModeShared)! }
    let bpp = 4   // rgba8Unorm and depth32Float are both 4 bytes per pixel
    var planes: [(String, Int, MTLBuffer, MTLBuffer)] = []   // name, slice, via root, via target
    let b = cb.makeBlitCommandEncoder()!
    func copy(_ t: MTLTexture, _ s: Int, _ o: MTLBlitOption, _ out: MTLBuffer, _ bytes: Int) {
        b.copy(from: t, sourceSlice: s, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: W, height: H, depth: 1),
               to: out, destinationOffset: 0, destinationBytesPerRow: W * bytes, destinationBytesPerImage: W * H * bytes, options: o)
    }
    for s in 0..<2 {
        let dOpt: MTLBlitOption = c.kind == .depthStencil ? .depthFromDepthStencil : []
        let name = c.kind == .color ? "colour" : "depth"
        let r = buf(W * H * bpp), v = buf(W * H * bpp)
        copy(root, s, dOpt, r, bpp); if s == c.slice { copy(target, 0, dOpt, v, bpp) }
        planes.append((name, s, r, v))
        if hasS {
            let rs = buf(W * H), vs = buf(W * H)
            copy(root, s, .stencilFromDepthStencil, rs, 1); if s == c.slice { copy(target, 0, .stencilFromDepthStencil, vs, 1) }
            planes.append(("stencil", s, rs, vs))
        }
    }
    b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    if let err = cb.error { print("[ERROR] \(c.label): \(err)"); return false }

    var summary: [String] = [], selfSummary: [String] = [], pass_ = true
    for (name, s, r, v) in planes {
        let drawn = s == c.slice
        let n = W * H, bad: Int, selfBad: Int
        switch name {
        case "depth":  let w: Float = drawn ? 0.25 : 0.5; bad = wrong(r, Float.self, n, [w]); selfBad = drawn ? wrong(v, Float.self, n, [w]) : 0
        case "stencil": let w: UInt8 = drawn ? 17 : 3; bad = wrong(r, UInt8.self, n, [w]); selfBad = drawn ? wrong(v, UInt8.self, n, [w]) : 0
        default: let w: [UInt8] = drawn ? [255, 0, 255, 255] : [0, 255, 0, 255]; bad = wrong(r, UInt8.self, n * 4, w) / 4; selfBad = drawn ? wrong(v, UInt8.self, n * 4, w) / 4 : 0
        }
        if bad > 0 { summary.append("\(name) slice\(s): \(bad)/\(n) px wrong"); pass_ = false }
        if drawn && name == "stencil" { selfSummary.append(selfBad == 0 ? "stencil read back through the written view: correct" : "stencil via view: \(selfBad) wrong") }
    }
    let pad = c.label.padding(toLength: 52, withPad: " ", startingAt: 0)
    print("[\(pass_ ? "PASS" : "FAIL")] \(pad) \(pass_ ? "all planes of both slices as expected" : summary.joined(separator: "; "))")
    if !pass_ && !selfSummary.isEmpty { print("       (\(selfSummary.joined(separator: "; ")))") }
    return pass_
}

print("device: \(dev.name)   ProcessInfo: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("--- headline: depth32Float_stencil8 2D array, 1 sample, plain render pass (no MSAA, no resolve)")
var ok = true
for s in 0..<2 { ok = run(Case(label: "direct slice view V1, slice \(s), 1 sample", kind: .depthStencil, nested: false, slice: s, samples: 1)) && ok }
for s in 0..<2 { ok = run(Case(label: "NESTED view V2 of V1, slice \(s), 1 sample", kind: .depthStencil, nested: true, slice: s, samples: 1)) && ok }
print("--- 4x multisample render, resolve into the view")
for s in 0..<2 { ok = run(Case(label: "direct slice view V1, slice \(s), 4x resolve", kind: .depthStencil, nested: false, slice: s, samples: 4)) && ok }
for s in 0..<2 { ok = run(Case(label: "NESTED view V2 of V1, slice \(s), 4x resolve", kind: .depthStencil, nested: true, slice: s, samples: 4)) && ok }
print("--- controls: nested views of other formats")
for n in [1, 4] {
    ok = run(Case(label: "depth32Float only, NESTED, slice 1, \(n) sample(s)", kind: .depthOnly, nested: true, slice: 1, samples: n)) && ok
    ok = run(Case(label: "rgba8Unorm colour, NESTED, slice 1, \(n) sample(s)", kind: .color, nested: true, slice: 1, samples: n)) && ok
}
print(ok ? "\nRESULT: all configurations PASS" : "\nRESULT: FAIL - at least one configuration produced wrong data")
exit(ok ? 0 : 1)
