//
//  InputCatcherGeometry.swift
//  LambdaVision
//
//  Size and placement experiments for the mouse catcher (debug API keys
//  `inputCatcherSize`, `inputCatcherPlacement`; not stored). Researched
//  2026-10-07 against the visionOS 26/27 SDK and docs:
//
//  - An app can't position a window, near or far, with or without an open
//    immersive space: "you can't directly manipulate window position or size
//    after the window appears" (visionOS › Positioning and sizing windows).
//    `WindowPlacement.Position` is only `utilityPanel` or relative to
//    another window (leading/trailing/above/below, `replacing` deprecated
//    for pushWindow); the system places the first window where the person
//    looks. UIWindowSceneGeometryPreferencesVision carries sizes only.
//    `immersiveSpaceDisplacement` is read-only. No head-following window.
//  - Windows use dynamic scale: "visionOS defines a point as an angle", and
//    a window moved away grows to keep its angular size (HIG › Spatial
//    layout › Scale). So far away buys nothing for a window; only its size
//    in points (= angle) matters, capped by the system's window maximum.
//    The pointer is drawn on the window in points too, so there's no
//    documented reason for it to shrink with distance.
//  - Head anchoring exists only for RealityKit content in an immersive
//    space ("You can only use AnchorEntity in an immersive space", visionOS
//    › Placing entities using head and device transform), e.g. SwiftUI via
//    ViewAttachmentComponent. Ours is a CompositorLayer space:
//    ImmersiveSpaceContentBuilder.buildBlock takes ONE content, so a
//    CompositorLayer can't sit beside a RealityView in it, and only one
//    immersive space can be open at a time.
//  - A volume (`.volumetric`) uses fixed scale (metres; HIG, WindowStyle
//    .volumetric), so a big volume covers more angle and its back face is
//    physically far. The system still picks where it goes.
//
//  So the prototypes: a bigger catcher window (`size`), and a big volume
//  with an almost invisible input-target plane at its back (`placement`).
//

import GameController
import RealityKit
import SwiftUI

nonisolated enum InputCatcherSize: String, CaseIterable, Identifiable, Sendable {
    case standard, large, max
    var id: String { rawValue }

    var points: CGSize {
        switch self {
        case .standard: CGSize(width: 4000, height: 2600)
        case .large: CGSize(width: 8000, height: 5200)
        case .max: CGSize(width: 20000, height: 13000)
        }
    }
}

nonisolated enum InputCatcherPlacement: String, CaseIterable, Identifiable, Sendable {
    /// The plain window (dynamic scale): the confirmed path.
    case window
    /// A fixed-scale volumetric window with a far plane at its back.
    case volume
    var id: String { rawValue }
}

enum InputCatcherVolume {
    /// Asked size in metres (width, height, depth); the system clamps.
    static let requestedMeters = SIMD3<Double>(8, 5, 6)
    /// The back plane's opacity: something has to be drawn for the pointer
    /// (a fully clear window didn't catch); 0.01 was invisible on device.
    static let planeOpacity: Float = 0.01
}

/// The volume scene. Same lifecycle hooks as the window (InputCatcher
/// tracks whichever id it opened).
struct InputCatcherVolumeWindow: SwiftUI.Scene {
    var body: some SwiftUI.Scene {
        Window("Mouse Capture Volume", id: InputCatcher.volumeWindowID) {
            InputCatcherVolumeView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: InputCatcherVolume.requestedMeters.x,
                     height: InputCatcherVolume.requestedMeters.y,
                     depth: InputCatcherVolume.requestedMeters.z, in: .meters)
        .volumeWorldAlignment(.gravityAligned)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .persistentSystemOverlays(.hidden)
    }
}

struct InputCatcherVolumeView: View {
    private var catcher = InputCatcher.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.physicalMetrics) private var metrics

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                let plane = ModelEntity(mesh: .generatePlane(width: 1, height: 1),
                                        materials: [Self.material()])
                plane.name = "catcherPlane"
                plane.components.set(InputTargetComponent())
                plane.components.set(CollisionComponent(shapes: [.generateBox(width: 1, height: 1, depth: 0.01)]))
                content.add(plane)
            } update: { content in
                // Fill the volume's back face (the farthest point we own).
                guard let plane = content.entities.first(where: { $0.name == "catcherPlane" }) else { return }
                let bounds = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
                let ext = bounds.extents
                plane.scale = [ext.x, ext.y, 1]
                plane.position = [bounds.center.x, bounds.center.y, bounds.min.z + 0.01]
            }
            .onAppear { report(proxy.size) }
            .onChange(of: proxy.size) { _, s in report(s) }
        }
        .volumeBaseplateVisibility(.hidden)
        .onContinuousHover { catcher.hover($0) }
        .gesture(SpatialEventGesture(coordinateSpace: .immersiveSpace)
            .onChanged { catcher.spatial($0) }
            .onEnded { catcher.spatial($0) })
        .background(SceneReader { catcher.attach(scene: $0) })
        .handlesGameControllerEvents(matching: .gamepad)
        .onAppear { catcher.windowAppeared() }
        .onDisappear { catcher.windowDisappeared() }
        .onChange(of: catcher.closeRequests) { dismissWindow() }
        .onChange(of: scenePhase) { _, phase in catcher.windowPhase(phase) }
    }

    private func report(_ size: Size3D) {
        let m = SIMD3<Double>(metrics.convert(size.width, to: .meters),
                              metrics.convert(size.height, to: .meters),
                              metrics.convert(size.depth, to: .meters))
        catcher.volumeSized(points: size, meters: m)
    }

    private static func material() -> UnlitMaterial {
        var m = UnlitMaterial(color: .white)
        m.blending = .transparent(opacity: .init(floatLiteral: InputCatcherVolume.planeOpacity))
        return m
    }
}
