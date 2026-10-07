//
//  InputCatcher.swift
//  LambdaVision
//
//  The workaround for the visionOS mouse-focus limit: GCMouse delivers
//  nothing while the pointer is in the full immersive space (CompositorLayer)
//  and not over one of the app's windows, and no API claims the mouse for an
//  immersive space (~/Memory: Projects visionos-input-window-focus). But the
//  system routes the mouse to the app whenever the pointer is over one of its
//  windows. So this is a large plain window with no glass and no system
//  controls, kept up in front of the player while a mouse is in play.
//  Confirmed on the headset 2026-10-07 with a visible tint: GCMouse flowed,
//  the mouse drove the game.
//
//  It has to draw something. With Color.clear (and a contentShape) the
//  pointer went straight through: the system pointer hit-tests drawn pixels,
//  not SwiftUI shapes. UIKit documents the same rule for its own hit-testing
//  (UIView.hitTest ignores views with an alpha below 0.01), so the default is
//  a white fill at 0.01 (`inputCatcherAlpha`, stored). If GCMouse stays
//  silent with a mouse in use, the effective alpha steps up on its own
//  (`alphaLadder`, capped), and stops stepping once an event comes through.
//
//  The decision rule, the events-per-second counter and the "isn't catching"
//  watch are RAVEInput's (`RAVEMouseCatcherRule`, `RAVEEventRate`,
//  `RAVEMouseCatcherWatch`), shared with Longwave; this file is the window
//  and its lifecycle.
//
//  What it does to input:
//  - Mouse: nothing of its own. GCMouse (MouseInput, via RAVEMouseSource)
//    reads the device; the window only makes the system send the events to
//    this app. Its pointer clicks are dropped (GCMouse already has them).
//  - Gaze-and-pinch: lands on the catcher instead of the immersive layer
//    wherever the catcher covers the view, so its spatial events go through
//    the layer's own handler (ImmersiveSpatialInput): a pinch fires in hands
//    mode, clicks the menu, bids for hands mode, exactly as on the layer.
//    ARKit hand tracking (finger gun, joystick, wheel) never involved it.
//  - Gamepad: claimed like every other window (.handlesGameControllerEvents).
//
//  When it's up (RAVEMouseCatcherRule): immersive space open, in a level, not
//  loading, no menu or console (they're gaze-and-pinch UI), Settings ›
//  Keyboard, mouse & gamepad › "Mouse capture window" on, and either the mode
//  is forced to keyboard+mouse, or Auto with a mouse connected (whatever the
//  last pinch picked: mouse events are what switch Auto back, and they only
//  come through the catcher).
//
//  Placement: visionOS gives an app no say. `defaultWindowPlacement` can
//  only place a window beside another of the app's windows, there's no
//  head-following window, and `windowManagerRole` has only `.automatic`. A
//  new window opens in front of the player, so the catcher re-centres by
//  reopening when the pointer leaves it (`onContinuousHover` .ended), at most
//  every few seconds.
//
//  Closing: SwiftUI's dismissWindow — the main window's and the catcher's
//  own — didn't close it once the immersive space had closed (headset,
//  2026-10-07: "still up … after asking it to close" for 20+ s). So the
//  catcher keeps its UIWindowScene, and whether it's open is read from UIKit
//  (the scene still connected and not background) rather than from
//  onAppear/onDisappear. When SwiftUI's dismissal hasn't landed within
//  `destroyAfter`, the scene session is destroyed through UIKit
//  (`requestSceneSessionDestruction`).
//
//  Diagnostics: GET /state carries `mouseEventsLastSecond` and an
//  `inputCatcher` object; while it's up a line is logged every few seconds
//  with the event count and the effective alpha.
//

import SwiftUI
import UIKit
import QuartzCore
import RAVEInput
import DebugTrace
import GameController

@MainActor @Observable
final class InputCatcher {
    static let shared = InputCatcher()
    static let windowID = "input-catcher"
    /// Requested size in points. Large on purpose: the system clamps a
    /// window to its maximum, and the bigger it is the less a turn of the
    /// head or a long mouse sweep takes the pointer off it.
    static let requestedSize = CGSize(width: 4000, height: 2600)

    /// The stored default fill opacity, until a headset sweep picks one.
    nonisolated static let defaultAlpha = 0.01
    /// The automatic steps when GCMouse stays silent; never above the last.
    static let alphaLadder: [Double] = [0.003, 0.01, 0.02, 0.03, 0.05]
    /// GCMouse silent this long, with a mouse in use and the catcher up,
    /// before the alpha steps up (and again after each step).
    static let silenceBeforeStep: TimeInterval = 2
    /// SwiftUI's dismissal gets this long before the scene is destroyed.
    static let destroyAfter: TimeInterval = 0.5

    // Settings (GameSettings pushes them).
    var enabled = true
    var recenterOnExit = true
    var alpha = InputCatcher.defaultAlpha {
        didSet { if alpha != oldValue { autoAlpha = nil; catchConfirmed = false } }
    }
    var outline = false
    var material = false
    /// How the window is filled (InputCatcherTechniques.swift). The alpha
    /// and its step-up apply to `.swiftuiFill` only.
    var technique: InputCatcherTechnique = .swiftuiFill
    /// Step the alpha up on its own when GCMouse stays silent. Off: draw
    /// exactly `alpha`, for A/B tests at a fixed value.
    var autoStep = true {
        didSet { if !autoStep { autoAlpha = nil } }
    }

    // State, for the view and GET /state.
    private(set) var isOpen = false
    private(set) var wanted = false
    private(set) var reason = "not started"
    private(set) var hovering = false
    private(set) var actualSize: CGSize?
    private(set) var opens = 0
    private(set) var recenters = 0
    private(set) var pinches = 0
    private(set) var autoSteps = 0
    private(set) var lastFinding: String?
    /// The automatic alpha, when it has stepped above the setting.
    private(set) var autoAlpha: Double?
    /// GCMouse events arrived while the catcher was up (at `confirmedAlpha`):
    /// automatic stepping stops until the alpha setting changes.
    private(set) var catchConfirmed = false
    private(set) var confirmedAlpha: Double?
    /// Bumped to ask the catcher's own view to dismiss its window.
    private(set) var closeRequests = 0
    private(set) var destructions = 0
    /// UIHoverGestureRecognizer callbacks (the `uiview` technique).
    private(set) var uikitHovers = 0

    /// What the window draws.
    var effectiveAlpha: Double { max(alpha, autoAlpha ?? 0) }

    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var dismissWindow: DismissWindowAction?
    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The catcher's UIKit scene, captured from inside its window.
    @ObservationIgnored private weak var scene: UIWindowScene?

    // Lifecycle bookkeeping.
    @ObservationIgnored private var requestedOpenAt: TimeInterval?
    @ObservationIgnored private var openRequestsUnanswered = 0
    @ObservationIgnored private var dismissingOurselves = false
    @ObservationIgnored private var closeAskedAt: TimeInterval?
    @ObservationIgnored private var lastStuckLogAt: TimeInterval = -.infinity
    @ObservationIgnored private var reopenNotBefore: TimeInterval = 0
    @ObservationIgnored private var openedAt: TimeInterval = 0
    @ObservationIgnored private var lastStepAt: TimeInterval = 0
    @ObservationIgnored private var warnedAtCap = false
    @ObservationIgnored private var hoverEndedAt: TimeInterval?
    @ObservationIgnored private var lastHoverPoint: CGPoint?
    @ObservationIgnored private var lastRecenterAt: TimeInterval = -.infinity
    @ObservationIgnored private var warnedNoActions = false
    @ObservationIgnored private var countedPinches = Set<SpatialEventCollection.Event.ID>()

    // Mouse diagnostics (MouseInput, main queue).
    @ObservationIgnored private var mouseEvents = RAVEEventRate()
    @ObservationIgnored private var mouseMoves = RAVEEventRate()
    @ObservationIgnored private var watch = RAVEMouseCatcherWatch()
    @ObservationIgnored private var lastLogAt: TimeInterval = 0
    @ObservationIgnored private var eventsAtLastLog = 0
    @ObservationIgnored private var movesAtLastLog = 0

    static let tickInterval: Duration = .milliseconds(250)
    /// The pointer has to stay off the catcher this long before it re-centres.
    static let recenterDelay: TimeInterval = 0.5
    /// And re-centring happens at most this often.
    static let recenterMinInterval: TimeInterval = 3
    /// The window closed by someone else while still wanted: wait this long
    /// before opening it again, so a system dismissal can't become a loop.
    static let externalCloseBackoff: TimeInterval = 3
    static let logInterval: TimeInterval = 3

    // MARK: Setup

    /// Window actions from the main window, which stays up under the
    /// immersive space; opening a window needs a SwiftUI action and the
    /// decision is made here, not in a view.
    func capture(open: OpenWindowAction, dismiss: DismissWindowAction) {
        openWindow = open
        dismissWindow = dismiss
    }

    /// Starts the decision loop (from the main window; safe to call again).
    func start(appModel: AppModel) {
        self.appModel = appModel
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    // MARK: Mouse diagnostics

    func recordMouse(_ event: RAVEMouseEvent) {
        let now = CACurrentMediaTime()
        switch event {
        case .connected, .disconnected:
            return
        case .moved:
            mouseEvents.record(at: now)
            mouseMoves.record(at: now)
        case .button, .scroll:
            mouseEvents.record(at: now)
        }
        watch.mouseEvent(at: now)
        if isOpen, !catchConfirmed {
            catchConfirmed = true
            confirmedAlpha = effectiveAlpha
            AppLog.input.log("[InputCatcher] GCMouse events arrive with the catcher up at alpha \(String(format: "%.3f", self.effectiveAlpha), privacy: .public); automatic stepping stops")
        }
    }

    /// A pointer spatial event reached the immersive layer (with a mouse
    /// connected): while the catcher is up, the pointer got past it.
    func pointerReachedLayer() {
        guard isOpen else { return }
        watch.pointerPassed(at: CACurrentMediaTime())
    }

    var mouseEventsLastSecond: Int { mouseEvents.lastSecond(at: CACurrentMediaTime()) }
    var mouseMovesLastSecond: Int { mouseMoves.lastSecond(at: CACurrentMediaTime()) }
    var mouseEventsTotal: Int { mouseEvents.total }
    var secondsSinceMouseEvent: Double? { mouseEvents.lastAt.map { CACurrentMediaTime() - $0 } }

    // MARK: The decision loop

    private func decide() -> RAVEMouseCatcherDecision {
        let ready = appModel?.gameSettings.isEngineReady ?? false
        let immersive = appModel?.immersiveSpaceState == .open
        let inGame = ready && lambda_debug_in_game() != 0
        let loading = ready && lambda_engine_loading() != 0
        let blocker: String? = !ready ? nil
            : lambda_menu_active() != 0 ? "menu open"
            : lambda_console_active() != 0 ? "console open" : nil
        let policy: RAVEMouseCatcherPolicy = switch InputModeState.setting {
        case .auto: .automatic
        case .keyboardMouse: .mouseForced
        case .hands, .gamepad: .otherForced
        }
        var decision = RAVEMouseCatcherRule.evaluate(.init(
            enabled: enabled,
            sceneActive: immersive && inGame && !loading,
            blockedBy: blocker,
            policy: policy,
            mouseConnected: MouseInput.connected,
            mouseModeActive: InputModeState.current == .keyboardMouse))
        if decision.reason == "scene inactive" {
            decision.reason = !immersive ? "immersive space closed" : loading ? "loading" : "not in game"
        }
        return decision
    }

    private func tick() {
        let now = CACurrentMediaTime()
        reconcileWithUIKit()
        let decision = decide()
        if decision.reason != reason {
            AppLog.input.log("[InputCatcher] \(decision.wanted ? "wanted" : "not wanted", privacy: .public): \(decision.reason, privacy: .public)")
        }
        wanted = decision.wanted
        reason = decision.reason

        if wanted {
            closeAskedAt = nil
            if isOpen {
                recenterIfPointerLeft(now: now)
                stepAlphaIfMouseSilent(now: now)
                checkWatch(now: now)
            } else if now >= reopenNotBefore, requestedOpenAt.map({ now - $0 > 2 }) ?? true {
                open(now: now)
            }
        } else if isOpen || requestedOpenAt != nil {
            close(now: now)
        }
        logActivity(now: now)
    }

    /// The truth about the window from UIKit: its scene connected and not in
    /// the background. onAppear/onDisappear and the scene phase alone left
    /// `isOpen` stale.
    private func reconcileWithUIKit() {
        guard isOpen else { return }
        guard let scene else { return }   // not captured yet: trust onAppear
        let connected = UIApplication.shared.connectedScenes.contains(scene)
        if !connected || scene.activationState == .background || scene.activationState == .unattached {
            AppLog.input.log("[InputCatcher] UIKit says the window is gone (\(connected ? "connected" : "disconnected", privacy: .public), \(Self.describe(scene.activationState), privacy: .public))")
            windowDisappeared()
        }
    }

    private func open(now: TimeInterval) {
        guard let openWindow else {
            if !warnedNoActions {
                warnedNoActions = true
                AppLog.input.error("[InputCatcher] can't open: the main window hasn't handed over its openWindow action")
            }
            return
        }
        if requestedOpenAt != nil {
            openRequestsUnanswered += 1
            if openRequestsUnanswered == 3 {
                AppLog.input.error("[InputCatcher] 3 open requests and no window: the main window's openWindow may be dead (main window closed?)")
            }
        }
        requestedOpenAt = now
        openWindow(id: Self.windowID)
    }

    /// SwiftUI first (the main window's action and the catcher's own); if the
    /// window is still up `destroyAfter` later, UIKit destroys its session.
    private func close(now: TimeInterval) {
        requestedOpenAt = nil
        guard isOpen else { return }
        dismissingOurselves = true
        guard let asked = closeAskedAt else {
            closeAskedAt = now
            dismissWindow?(id: Self.windowID)
            closeRequests += 1
            return
        }
        guard now - asked >= Self.destroyAfter else { return }
        if now - lastStuckLogAt > 5 {
            lastStuckLogAt = now
            let state = scene.map { Self.describe($0.activationState) } ?? "no scene captured"
            AppLog.input.error("[InputCatcher] still up \(String(format: "%.1f", now - asked), privacy: .public) s after dismissWindow (\(self.reason, privacy: .public), scene \(state, privacy: .public)); destroying its scene session")
        }
        if let scene {
            destructions += 1
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
                AppLog.input.error("[InputCatcher] scene session destruction failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            dismissWindow?(id: Self.windowID)
            closeRequests += 1
        }
        closeAskedAt = now
    }

    private func recenterIfPointerLeft(now: TimeInterval) {
        guard recenterOnExit, !hovering, let ended = hoverEndedAt,
              now - ended >= Self.recenterDelay,
              now - lastRecenterAt >= Self.recenterMinInterval else { return }
        lastRecenterAt = now
        hoverEndedAt = nil
        recenters += 1
        AppLog.input.log("[InputCatcher] pointer left the catcher: re-centring (#\(self.recenters))")
        close(now: now)
        // Reopened by the next ticks, once the dismissal has landed.
        reopenNotBefore = now + 0.3
    }

    /// GCMouse silent while a mouse is in use and the catcher is up: the
    /// pointer probably goes through it, so draw a little more.
    private func stepAlphaIfMouseSilent(now: TimeInterval) {
        guard autoStep, technique == .swiftuiFill, !catchConfirmed, MouseInput.connected,
              InputModeState.current == .keyboardMouse || InputModeState.setting == .keyboardMouse else { return }
        let quietSince = max(openedAt, lastStepAt, mouseEvents.lastAt ?? 0)
        guard now - quietSince >= Self.silenceBeforeStep else { return }
        stepAlpha(now: now, why: "GCMouse silent \(String(format: "%.0f", now - quietSince)) s")
    }

    private func stepAlpha(now: TimeInterval, why: String) {
        let current = effectiveAlpha
        guard let next = Self.alphaLadder.first(where: { $0 > current + 1e-6 }) else {
            if !warnedAtCap {
                warnedAtCap = true
                AppLog.input.error("[InputCatcher] \(why, privacy: .public) at the top of the ladder (alpha \(String(format: "%.3f", current), privacy: .public)); not going higher on its own — try inputCatcherOutline or a higher inputCatcherAlpha")
            }
            lastStepAt = now
            return
        }
        autoAlpha = next
        autoSteps += 1
        lastStepAt = now
        AppLog.input.error("[InputCatcher] \(why, privacy: .public): alpha \(String(format: "%.3f", current), privacy: .public) → \(String(format: "%.3f", next), privacy: .public) (step #\(self.autoSteps))")
    }

    private func checkWatch(now: TimeInterval) {
        guard let finding = watch.check(now: now, catcherOpen: isOpen) else { return }
        lastFinding = finding.rawValue
        switch finding {
        case .pointerPassedCatcher:
            AppLog.input.error("[InputCatcher] a pointer event reached the immersive layer with the catcher up")
            if autoStep, technique == .swiftuiFill, !catchConfirmed { stepAlpha(now: now, why: "pointer reached the layer") }
        case .pointerOnCatcherMouseSilent:
            AppLog.input.error("[InputCatcher] the pointer moves on the catcher but GCMouse is silent (alpha \(String(format: "%.3f", self.effectiveAlpha), privacy: .public))")
        }
    }

    private func logActivity(now: TimeInterval) {
        guard isOpen, now - lastLogAt >= Self.logInterval else { return }
        let events = mouseEvents.total - eventsAtLastLog
        let moves = mouseMoves.total - movesAtLastLog
        let span = lastLogAt == 0 ? Self.logInterval : now - lastLogAt
        lastLogAt = now
        eventsAtLastLog = mouseEvents.total
        movesAtLastLog = mouseMoves.total
        AppLog.input.log("[InputCatcher] up: \(events) GCMouse events (\(moves) moves) in \(String(format: "%.1f", span), privacy: .public) s, pointer \(self.hovering ? "on" : "off", privacy: .public) the catcher, mode \(InputModeState.current.label, privacy: .public), technique \(self.technique.rawValue, privacy: .public), alpha \(String(format: "%.3f", self.effectiveAlpha), privacy: .public)\(self.autoAlpha != nil ? " (auto)" : "", privacy: .public)\(self.material ? " material" : "", privacy: .public)")
    }

    // MARK: From the window

    func windowAppeared() {
        guard !isOpen else { return }
        isOpen = true
        requestedOpenAt = nil
        openRequestsUnanswered = 0
        closeAskedAt = nil
        hovering = false
        hoverEndedAt = nil
        lastHoverPoint = nil
        watch.reset()
        opens += 1
        let now = CACurrentMediaTime()
        openedAt = now
        lastLogAt = now
        eventsAtLastLog = mouseEvents.total
        movesAtLastLog = mouseMoves.total
        AppLog.input.log("[InputCatcher] window up (#\(self.opens), technique \(self.technique.rawValue, privacy: .public), alpha \(String(format: "%.3f", self.effectiveAlpha), privacy: .public))")
    }

    func windowDisappeared() {
        guard isOpen else { return }
        isOpen = false
        hovering = false
        closeAskedAt = nil
        scene = nil
        if !dismissingOurselves {
            // Closed by the system or the player while we still want it.
            reopenNotBefore = CACurrentMediaTime() + Self.externalCloseBackoff
            AppLog.input.log("[InputCatcher] window closed from outside; reopening no sooner than \(Int(Self.externalCloseBackoff)) s")
        }
        dismissingOurselves = false
        AppLog.input.log("[InputCatcher] window down")
    }

    /// The catcher scene's phase, for the log; UIKit (reconcileWithUIKit)
    /// decides whether it's open.
    func windowPhase(_ phase: ScenePhase) {
        AppLog.input.log("[InputCatcher] window scene phase \(String(describing: phase), privacy: .public)")
        if phase == .active, !isOpen { windowAppeared() }
    }

    /// The catcher's UIWindowScene, from a view inside it.
    func attach(scene: UIWindowScene) {
        guard self.scene !== scene else { return }
        self.scene = scene
        AppLog.input.log("[InputCatcher] scene captured (\(Self.describe(scene.activationState), privacy: .public))")
    }

    func sized(_ size: CGSize) {
        guard size != actualSize else { return }
        actualSize = size
        AppLog.input.log("[InputCatcher] window size \(Int(size.width))×\(Int(size.height)) pt (asked \(Int(Self.requestedSize.width))×\(Int(Self.requestedSize.height)))")
    }

    func hover(_ phase: HoverPhase) {
        switch phase {
        case .active(let point):
            if !hovering { hoverEndedAt = nil }
            hovering = true
            if let last = lastHoverPoint, last != point { watch.hoverMoved(at: CACurrentMediaTime()) }
            lastHoverPoint = point
        case .ended:
            hovering = false
            hoverEndedAt = CACurrentMediaTime()
            lastHoverPoint = nil
        }
    }

    /// Spatial events on the catcher: the layer's handler, as if they had
    /// landed on it (rays in `.immersiveSpace` coordinates).
    func spatial(_ events: SpatialEventCollection) {
        for event in events where event.kind == .indirectPinch || event.kind == .directPinch {
            if event.phase == .active {
                if countedPinches.insert(event.id).inserted { pinches += 1 }
            } else {
                countedPinches.remove(event.id)
            }
        }
        guard let appModel else { return }
        ImmersiveSpatialInput.handle(events, appModel: appModel, source: .catcher)
    }

    func uikitHovered() {
        uikitHovers += 1
        if uikitHovers == 1 || uikitHovers % 200 == 0 {
            AppLog.input.log("[InputCatcher] UIKit hover on the catcher (#\(self.uikitHovers))")
        }
    }

    private static func describe(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .unattached: "unattached"
        case .foregroundActive: "foregroundActive"
        case .foregroundInactive: "foregroundInactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    // MARK: GET /state

    nonisolated struct Status: Encodable, Sendable {
        let enabled: Bool
        let wanted: Bool
        let open: Bool
        let reason: String
        let technique: String
        let uikitHovers: Int
        let alphaSetting: Double
        let effectiveAlpha: Double
        let autoSteps: Int
        let catchConfirmed: Bool
        let confirmedAlpha: Double?
        let outline: Bool
        let material: Bool
        let recenterOnExit: Bool
        let pointerOnCatcher: Bool
        let sizePt: [Double]?
        let sceneState: String?
        let opens: Int
        let recenters: Int
        let destructions: Int
        let pinches: Int
        let lastFinding: String?
    }

    var status: Status {
        Status(enabled: enabled, wanted: wanted, open: isOpen, reason: reason,
               technique: technique.rawValue, uikitHovers: uikitHovers,
               alphaSetting: alpha, effectiveAlpha: effectiveAlpha, autoSteps: autoSteps,
               catchConfirmed: catchConfirmed, confirmedAlpha: confirmedAlpha,
               outline: outline, material: material,
               recenterOnExit: recenterOnExit, pointerOnCatcher: hovering,
               sizePt: actualSize.map { [Double($0.width), Double($0.height)] },
               sceneState: scene.map { Self.describe($0.activationState) },
               opens: opens, recenters: recenters, destructions: destructions,
               pinches: pinches, lastFinding: lastFinding)
    }
}

// MARK: - The window

/// The catcher's scene. Plain style (no glass), no system controls, the
/// content's size, never restored at launch.
struct InputCatcherWindow: Scene {
    var body: some Scene {
        Window("Mouse Capture", id: InputCatcher.windowID) {
            InputCatcherView()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(InputCatcher.requestedSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .persistentSystemOverlays(.hidden)
    }
}

struct InputCatcherView: View {
    private var catcher = InputCatcher.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        fillView
            .frame(width: InputCatcher.requestedSize.width, height: InputCatcher.requestedSize.height)
            .contentShape(Rectangle())
            .background(SceneReader { catcher.attach(scene: $0) })
            .onGeometryChange(for: CGSize.self) { $0.size } action: { catcher.sized($0) }
            // No hover highlight anywhere in the window.
            .hoverEffectDisabled()
            .onContinuousHover { catcher.hover($0) }
            // In immersive-space coordinates, so the gaze ray can be used
            // like the layer's (ImmersiveSpatialInput.Source.catcher).
            .gesture(SpatialEventGesture(coordinateSpace: .immersiveSpace)
                .onChanged { catcher.spatial($0) }
                .onEnded { catcher.spatial($0) })
            // Hide the grabber and close button (and the window's ornaments).
            .persistentSystemOverlays(.hidden)
            .handlesGameControllerEvents(matching: .gamepad)
            .onAppear { catcher.windowAppeared() }
            .onDisappear { catcher.windowDisappeared() }
            .onChange(of: catcher.closeRequests) { dismissWindow() }
            .onChange(of: scenePhase) { _, phase in catcher.windowPhase(phase) }
    }

    /// The fill (InputCatcherTechniques.swift), plus the debug outline.
    private var fillView: some View {
        let a = catcher.effectiveAlpha
        return ZStack {
            InputCatcherFill(technique: catcher.technique, alpha: a, material: catcher.material,
                             onUIKitHover: { catcher.uikitHovered() })
            if catcher.outline {
                Rectangle().stroke(Color.cyan.opacity(0.6), lineWidth: 6)
                    .allowsHitTesting(false)
                Text("Mouse capture window  ·  \(catcher.technique.rawValue)  ·  alpha \(String(format: "%.3f", a))")
                    .font(.largeTitle)
                    .foregroundStyle(.cyan.opacity(0.7))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Hands the hosting UIWindowScene to `found` once the view is in a window.
private struct SceneReader: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.found = found
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.found = found
        if let scene = uiView.window?.windowScene { found(scene) }
    }

    final class ProbeView: UIView {
        var found: ((UIWindowScene) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found?(scene) }
        }
    }
}

extension View {
    /// Hands this view's scene actions to the catcher, so it can open and
    /// dismiss its window from the decision loop. On the main window only,
    /// which stays up under the immersive space: an action captured from a
    /// window that later closes (the catcher itself, Console) may not open
    /// anything once its scene is gone.
    func capturesInputCatcherActions() -> some View {
        modifier(CaptureInputCatcherActions())
    }
}

private struct CaptureInputCatcherActions: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    func body(content: Content) -> some View {
        content.onAppear {
            InputCatcher.shared.capture(open: openWindow, dismiss: dismissWindow)
        }
    }
}
