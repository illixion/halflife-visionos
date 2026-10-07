//
//  LambdaVisionApp.swift
//  LambdaVision
//
//  Created by Ixion on 10/05/2026.
//

import RAVEConsole
import RAVEHolo
import ARKit
import AVFAudio
import CompositorServices
import GameController
import SwiftUI
import DebugTrace
import DebugTraceUI

// Audio-session interruption recovery. visionOS interrupts the session on
// events as mundane as closing the app's 2D window, and the matching
// `.ended` notification is NOT guaranteed to arrive (observed: repeated
// `began` with no `ended` → permanent silence). So on interruption, poll:
// try to reclaim the session every second and restart the AudioQueue as
// soon as the system permits.
@MainActor
enum AudioSessionRecovery {
    private static var retry: Task<Void, Never>?

    static func interruptionBegan() {
        lambda_snd_activate(0)
        retry?.cancel()
        retry = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if (try? AVAudioSession.sharedInstance().setActive(true)) != nil {
                    AppLog.app.log("[LambdaVision] audio session reclaimed — restarting queue")
                    lambda_snd_activate(1)
                    return
                }
            }
        }
    }

    static func interruptionEnded() {
        retry?.cancel()
        retry = nil
        try? AVAudioSession.sharedInstance().setActive(true)
        lambda_snd_activate(1)
    }
}

// Held-pinch state for the fire trigger (IDs of in-flight pinches).
// Spatial events arrive serially, so a plain Set is fine.
private enum PinchFire {
    static var active = Set<SpatialEventCollection.Event.ID>()
}

// IDs of menu pinches that have already registered their single click. The
// .active phase repeats every frame while the pinch is held, so without this
// a held pinch would rapid-fire menu selections (one per frame).
private enum MenuPinch {
    static var clicked = Set<SpatialEventCollection.Event.ID>()
}

// Pinches already counted as a bid for hands mode (once per pinch; .active
// repeats every frame).
private enum HandBid {
    static var seen = Set<SpatialEventCollection.Event.ID>()
}

// Pointer (mouse click) events seen by the immersive layer, for a log line.
private enum PointerProbe {
    static var logged = 0
}

// Pinches that landed on a palm debug panel button (a tracking area). They
// act once, on the first .active, and never fire or click the menu.
private enum PanelPinch {
    static var pressed = Set<SpatialEventCollection.Event.ID>()
}

/// Gaze-and-pinch (and pointer) spatial events, from the immersive layer and
/// from the invisible mouse-capture window (InputCatcher), which sits in
/// front of the layer and so receives the pinches aimed at it. One handler,
/// so a pinch does the same thing wherever it lands: fire in hands mode, a
/// menu click, a bid for hands mode.
@MainActor
enum ImmersiveSpatialInput {
    enum Source {
        /// The CompositorLayer: selection rays in world space (ARKit, +Y up).
        case layer
        /// The catcher window's SpatialEventGesture in `.immersiveSpace`
        /// coordinates: SwiftUI's convention, +Y down (points; only the
        /// direction is used, so the scale doesn't matter).
        case catcher

        func worldDirection(_ d: Vector3D) -> SIMD3<Float> {
            switch self {
            case .layer: SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z))
            case .catcher: simd_normalize(SIMD3<Float>(Float(d.x), -Float(d.y), Float(d.z)))
            }
        }
    }

    static func handle(_ events: SpatialEventCollection, appModel: AppModel, source: Source) {
        // When the stock Half-Life menu is up it owns gaze+pinch: a
        // pinch clicks the item the eyes are on (like a visionOS
        // window), and must NOT fire the weapon.
        let menuActive = lambda_menu_active() != 0
        for event in events {
            // A mouse click can also arrive as a pointer event; with a
            // mouse connected GCMouse owns clicks (MouseInput), so it
            // must not fire or click the menu twice.
            if event.kind == .pointer, MouseInput.connected {
                // On the layer while the catcher is up: the pointer got past
                // it (InputCatcher's watch reacts).
                if source == .layer, event.phase == .active {
                    InputCatcher.shared.pointerReachedLayer()
                }
                // Whether mouse clicks reach the immersive layer at
                // all (ISSUES.md, mouse focus): log the first few.
                if PointerProbe.logged < 8, event.phase == .active {
                    PointerProbe.logged += 1
                    AppLog.input.log("[LambdaVision] pointer event in the immersive space (ray \(event.selectionRay != nil ? "Y" : "N", privacy: .public))")
                }
                continue
            }
            // A pinch on a palm debug panel button: the system routed
            // it to that tracking area, so it is the button's — not
            // the trigger's, not the menu's.
            if let control = PalmDebugPanel.Control(rawValue: event.trackingAreaIdentifier.rawValue) {
                if event.phase == .active {
                    if PanelPinch.pressed.insert(event.id).inserted {
                        PalmDebugPanel.interaction.recordPress(control.rawValue, at: CACurrentMediaTime())
                        Task { @MainActor in appModel.gameSettings.performDebugPanelControl(control) }
                    }
                } else {
                    PanelPinch.pressed.remove(event.id)
                }
                continue
            }
            switch event.phase {
            case .active:
                let dir = event.selectionRay.map { source.worldDirection($0.direction) }
                if menuActive {
                    // Keep the cursor under the gaze while held (for
                    // highlight), but click only ONCE per pinch —
                    // .active repeats each frame.
                    if let d = dir, let (mx, my) = Renderer.menuCursorFromGaze(d) {
                        lambda_menu_set_cursor(Int32(mx), Int32(my))
                        if MenuPinch.clicked.insert(event.id).inserted {
                            lambda_menu_click()
                        }
                    }
                    continue
                }
                // A look-and-pinch is the hands' bid for the input mode;
                // outside hands mode it doesn't fire (the hands have
                // stepped aside for the keyboard, mouse or gamepad).
                if HandBid.seen.insert(event.id).inserted {
                    InputModeState.deviceUsed(.hands, now: CACurrentMediaTime())
                }
                if InputModeState.current != .hands { continue }
                // When immersive gesture input is on, the render-thread
                // gestures own both hands (dominant index-curl fires,
                // off-hand pinch drives the joystick), so the pinch must
                // NOT also fire. Gate the press only — a release still
                // clears below, so toggling mid-pinch can't stick fire.
                if Renderer.gestureInputEnabled { continue }
                // Stage the gaze ray BEFORE +attack so the shot
                // aims where the eyes point (renderFrame converts
                // it to an aim offset for the weapon code).
                if let d = dir { Renderer.setGazeRay(direction: d) }
                if PinchFire.active.insert(event.id).inserted,
                   PinchFire.active.count == 1 {
                    _ = "+attack".withCString { lambda_gl_worker_cmd($0) }
                }
            case .ended, .cancelled:
                HandBid.seen.remove(event.id)
                if menuActive { MenuPinch.clicked.remove(event.id); continue }
                if PinchFire.active.remove(event.id) != nil,
                   PinchFire.active.isEmpty {
                    _ = "-attack".withCString { lambda_gl_worker_cmd($0) }
                    Renderer.setGazeRay(direction: nil)
                }
            @unknown default:
                break
            }
        }
    }
}

struct ImmersiveSpaceContent: CompositorContent {

    var appModel: AppModel

    var body: some CompositorContent {
        CompositorLayer(configuration: self) { @MainActor layerRenderer in
            // Crash dump goes here; pull via `xcrun devicectl ... pull` or
            // the Files app. Overwritten on each crash.
            if let docs = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true) {
                let path = docs.appendingPathComponent("crash.log").path
                path.withCString { lambda_set_crash_log_path($0) }
                AppLog.app.log("[LambdaVision] crash log path: \(path, privacy: .private)")
            }
            // The engine's AudioQueue backend (snd_visionos.c) plays into
            // the app's audio session; without an explicitly activated
            // .playback session the system can leave the queue's I/O
            // thread suspended (observed on device: the first render
            // callback never completes).
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: [.mixWithOthers])
                // Bypass the system's spatializer. By default visionOS
                // spatializes the app's audio and anchors it to the app's
                // first window — sitting ON TOP of the mixes we already
                // produce. That double layer is what made PHASE's own
                // binaural output deafening while the window was open and
                // silent when it was closed (no window = no anchor), and it
                // window-pinned the AudioQueue bed. Bypassed = our stereo/
                // binaural output plays through unmodified; PHASE does the
                // spatialization, the bed stays head-locked.
                try session.setIntendedSpatialExperience(.bypassed)
                try session.setActive(true)
            } catch {
                AppLog.app.log("[LambdaVision] AVAudioSession activation failed: \(error)")
            }
            // System interruptions (Siri, alerts, route changes) stop the
            // AudioQueue and nothing restarts it — the game goes silent
            // until the user hides/shows the immersive space. Drive the
            // same pause/resume machinery from the session notifications.
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main) { note in
                    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    switch type {
                    case .began:
                        AppLog.app.log("[LambdaVision] audio interruption began — pausing queue")
                        Task { @MainActor in AudioSessionRecovery.interruptionBegan() }
                    case .ended:
                        AppLog.app.log("[LambdaVision] audio interruption ended — restarting queue")
                        Task { @MainActor in AudioSessionRecovery.interruptionEnded() }
                    @unknown default:
                        break
                    }
                }
            // Media services daemon crash/reset: the session and queue are
            // both orphaned — reactivate and restart.
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil, queue: .main) { _ in
                    AppLog.app.log("[LambdaVision] media services reset — restarting audio")
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(.playback, options: [.mixWithOthers])
                    try? session.setActive(true)
                    lambda_snd_activate(0)
                    lambda_snd_activate(1)
                }
            // Gaze + pinch = trigger. CompositorServices delivers indirect
            // pinch events straight to the layer in a full immersive space.
            // A held pinch holds +attack (HL's automatic weapons fire while
            // the trigger is down); release/cancel lets go.
            layerRenderer.onSpatialEvent = { events in
                ImmersiveSpatialInput.handle(events, appModel: appModel, source: .layer)
            }
            KeyboardInput.shared.start()
            Renderer.startRenderLoop(layerRenderer, appModel: appModel, arSession: ARKitSession())
        }
        // Hide the palm-up Home indicator: the HEV holograms and the hand
        // gestures all live on the hands. On a CompositorLayer this has to be
        // the content-level preference — the scene-level one alone hid it
        // for the first palm-up only (found in Oneiros's Metal host).
        .persistentSystemOverlays(.hidden)
    }
}

extension ImmersiveSpaceContent: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        // Foveation on: the compositor samples our drawable at panel density
        // in the fovea, which is what lets the flat engine render reach
        // native-looking sharpness where the user looks. The display pass
        // binds drawable.rasterizationRateMaps.first and samples the colorMap
        // through interpolated varyings — with a rate map bound, varyings
        // interpolate in logical (screen) space, so each physical fragment
        // fetches the correct colorMap texel and the compositor's unwarp
        // reconstructs a straight image. (The V-shape artifact seen earlier
        // came from foveated presentation WITHOUT the rate map bound at
        // render time.)
        configuration.isFoveationEnabled = capabilities.supportsFoveation

        let supportedLayouts = capabilities.supportedLayouts(options: [])
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated

        configuration.supportsMTL4 = true

        // Tracking areas: the palm debug panel's buttons get system gaze
        // hover and pinches routed to them (RAVEHoloCompositor).
        RAVEHoloCompositor.configureTrackingAreas(capabilities: capabilities, configuration: &configuration)
    }
}

@main
struct LambdaVisionApp: App {

    @State private var appModel = AppModel()
    // The app-wide phase (all scenes): the debug server re-checks its
    // listener when it returns to active (LambdaDebugServer).
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLog.configureDebugTrace()
        // DebugTrace's start rule plus Settings › Advanced › Debug server,
        // on ports clear of the Wi-Fi manager's (DebugEndpoints).
        LambdaDebugServer.apply(AppSettingsStore.debugServer)
    }

    var body: some Scene {
        // Single-instance launcher/settings window — we only ever want one
        // copy of the start menu.
        Window("Lambda VisionPro", id: "main") {
            ContentView()
                .environment(appModel)
                .debugApprovalPrompts()
                // Route gamepad input to the app instead of system focus
                // navigation — without this, polled GCController values
                // freeze after a stick release (a known GCController quirk).
                .handlesGameControllerEvents(matching: .gamepad)
                // "Open in LambdaVision" (AirDrop, Files, Share): a game zip.
                .onOpenURL { url in appModel.library.open(url) }
        }
        .onChange(of: scenePhase) { _, phase in LambdaDebugServer.scenePhaseChanged(phase) }

        // In-app log viewer. This app renders through CompositorServices and
        // has no tab bar, so the console is its own window.
        // Every window claims the gamepad (see GamepadInput): whichever one
        // the gaze rests on decides whether the pad reaches the game or the
        // system's focus navigation, which freezes polled values — a stick
        // pushed at that moment stays pushed.
        Window("Console", id: "console") {
            RAVEConsoleScreen()
                .handlesGameControllerEvents(matching: .gamepad)
                .debugApprovalPrompts()
        }
        .defaultLaunchBehavior(.suppressed)

        // Live FPS/frame-time HUD, same window-based approach as Console —
        // stays visible over the immersive space since it's never dismissed.
        Window("Performance", id: "performance") {
            PerformanceHUDScreen()
                .handlesGameControllerEvents(matching: .gamepad)
                .debugApprovalPrompts()
        }
        .defaultLaunchBehavior(.suppressed)

        // DebugTrace's "Allow debug access?" prompt, which the server opens
        // itself: over the immersive space there is no UIKit window for a
        // system alert.
        DebugApprovalWindow()

        // The invisible mouse-capture window (InputCatcher): over the
        // immersive space the system only sends GCMouse events to the app
        // while the pointer is over one of its windows.
        InputCatcherWindow()
        InputCatcherPromptWindow()

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSpaceContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // visionOS composites the user's real hands/forearms over full
        // immersion by default (a safety passthrough, independent of
        // immersionStyle) — that layer sits on top of our render and
        // occludes any weapon model drawn "in" the hand. Hide it; ArmPass
        // draws a wireframe skeleton in its place (see Renderer.swift).
        .upperLimbVisibility(.hidden)
        .persistentSystemOverlays(.hidden)
    }
}