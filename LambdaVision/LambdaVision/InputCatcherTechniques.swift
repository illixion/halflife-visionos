//
//  InputCatcherTechniques.swift
//  LambdaVision
//
//  The ways the mouse catcher can fill its window, for a headset sweep
//  (debug API key `inputCatcherTechnique`, stored). Background: the visionOS
//  pointer hit-tests what reaches the render server. A SwiftUI Color.clear
//  (or opacity 0) with a contentShape let it straight through, white at
//  0.003 caught. The invisible window that caught the mouse in Convolution
//  was a photo viewer whose MTKView (a CAMetalLayer, isOpaque false, paused,
//  draw-on-demand) never got a drawable, inside a `.windowStyle(.plain)`
//  window, with `.contentShape(.rect).onTapGesture` on it — tapping toggled
//  its ornaments (Hypnos MetalImageView / PhotoDisplayView, 7e4589e^). The
//  guess: SwiftUI drops a clear view from the layer tree, while a real UIKit
//  layer with opacity 1 stays in it and counts, drawn or not.
//

import DebugTrace
import MetalKit
import RealityKit
import SwiftUI
import UIKit

nonisolated enum InputCatcherTechnique: String, CaseIterable, Identifiable, Sendable {
    /// SwiftUI Color.white at `inputCatcherAlpha` (the only one the alpha and
    /// its automatic step-up apply to). Catches at 0.003; 0 doesn't.
    case swiftuiFill
    /// A plain UIView, layer opacity 1, backgroundColor .clear, interaction
    /// on, with a UIHoverGestureRecognizer (counted in /state).
    case uiview
    /// The Convolution case: an MTKView (CAMetalLayer), not opaque, paused,
    /// no delegate, never presenting a drawable.
    case metalEmpty
    /// The same MTKView presenting one drawable cleared to all zeros, once.
    case metalClear
    /// A RealityView holding one invisible entity with an input target and
    /// a collision box across the window, no model.
    case realityTarget
    var id: String { rawValue }
}

/// The catcher's fill for `technique`.
struct InputCatcherFill: View {
    let technique: InputCatcherTechnique
    let alpha: Double
    let material: Bool
    /// UIKit hover on the `uiview` technique.
    let onUIKitHover: () -> Void

    var body: some View {
        switch technique {
        case .swiftuiFill:
            if material {
                Rectangle().fill(.ultraThinMaterial).opacity(alpha)
            } else {
                Color.white.opacity(alpha)
            }
        case .uiview:
            ClearUIKitView(onHover: onUIKitHover)
        case .metalEmpty:
            EmptyMetalView(presentOnce: false)
        case .metalClear:
            EmptyMetalView(presentOnce: true)
        case .realityTarget:
            InvisibleRealityTarget()
        }
    }
}

// MARK: - UIView

private struct ClearUIKitView: UIViewRepresentable {
    let onHover: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.layer.opacity = 1
        v.isOpaque = false
        v.isUserInteractionEnabled = true
        v.addGestureRecognizer(UIHoverGestureRecognizer(target: context.coordinator,
                                                        action: #selector(Coordinator.hovered(_:))))
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onHover = onHover
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHover: onHover) }

    final class Coordinator: NSObject {
        var onHover: () -> Void
        init(onHover: @escaping () -> Void) { self.onHover = onHover }
        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .changed { onHover() }
        }
    }
}

// MARK: - Metal

/// An MTKView configured like Hypnos's MetalImageView (not opaque, clear
/// colour zero, paused, draw on demand), minus the image.
private struct EmptyMetalView: UIViewRepresentable {
    let presentOnce: Bool

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = false
        view.layer.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        if presentOnce {
            view.enableSetNeedsDisplay = true
            view.delegate = context.coordinator
            view.setNeedsDisplay()
        } else {
            // No delegate and no setNeedsDisplay: it never draws.
            view.enableSetNeedsDisplay = false
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // A cleared frame at the real size, once it's laid out.
        if presentOnce, !context.coordinator.presented { uiView.setNeedsDisplay() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        private(set) var presented = false
        private var queue: MTLCommandQueue?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            if !presented { view.setNeedsDisplay() }
        }

        func draw(in view: MTKView) {
            guard !presented, view.drawableSize.width > 0, let device = view.device,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
            if queue == nil { queue = device.makeCommandQueue() }
            guard let buffer = queue?.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding()   // loadAction .clear with clearColor zero
            buffer.present(drawable)
            buffer.commit()
            presented = true
            AppLog.input.log("[InputCatcher] metalClear presented one cleared drawable \(Int(view.drawableSize.width))×\(Int(view.drawableSize.height))")
        }
    }
}

// MARK: - RealityKit

/// One entity with no model: an input target over a collision box the size
/// of the window (and then some; the window bounds clip it).
private struct InvisibleRealityTarget: View {
    var body: some View {
        RealityView { content in
            let entity = Entity()
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(shapes: [.generateBox(width: 10, height: 10, depth: 0.01)]))
            content.add(entity)
        }
    }
}
