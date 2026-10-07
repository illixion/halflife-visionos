//
//  InputCatcher.swift
//  LambdaVision
//
//  The workaround for the visionOS mouse-focus limit: GCMouse delivers
//  nothing while the pointer is in the full immersive space (CompositorLayer)
//  and not over one of the app's windows, and no API claims the mouse for an
//  immersive space (~/Memory: Projects visionos-input-window-focus). But the
//  system routes the mouse to the app whenever the pointer is over one of its
//  windows, and a window doesn't need to show anything to count. So this is a
//  large plain window with no glass, no content and no system controls, kept
//  up in front of the player while a mouse is in play. Confirmed on the
//  headset 2026-10-07 (fill = visible): GCMouse flowed, the mouse drove the
//  game.
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
//  come through the catcher — taking it down on a pinch trapped the game in
//  hands mode on the first headset test).
//
//  Placement: visionOS gives an app no say. `defaultWindowPlacement` can
//  only place a window beside another of the app's windows, there's no
//  head-following window, and `windowManagerRole` has only `.automatic`. A
//  new window opens in front of the player, so the catcher re-centres by
//  reopening when the pointer leaves it (`onContinuousHover` .ended), at most
//  every few seconds.
//
//  Closing: through the main window's captured `dismissWindow(id:)` and the
//  catcher's own `dismissWindow`, and a catcher scene gone to the background
//  counts as closed: once, the state still said open after the immersive
//  space had closed.
//
//  Diagnostics: GET /state carries `mouseEventsLastSecond` and an
//  `inputCatcher` object; while it's up a line is logged every few seconds.
//  If a pointer event reaches the layer while the catcher is up (the pointer
//  went through a clear catcher), the fill steps up to `faint` on its own.
//

import SwiftUI
import QuartzCore
import RAVEInput
import DebugTrace
import GameController

/// Settings › Keyboard, mouse & gamepad › catcher fill, for A/B on the
/// headset (debug API key `inputCatcherFill`, not stored).
nonisolated enum InputCatcherFill: String, CaseIterable, Identifiable, Sendable {
    /// Nothing drawn: Color.clear with a content shape (the default).
    case clear
    /// An alpha the eye can't see, in case the system hit-tests by pixels.
    case faint
    /// A visible tint and outline, to see where the system put it.
    case visible
    var id: String { rawValue }
}

@MainActor @Observable
final class InputCatcher {
    static let shared = InputCatcher()
    static let windowID = "input-catcher"
    /// Requested size in points. Large on purpose: the system clamps a
    /// window to its maximum, and the bigger it is the less a turn of the
    /// head or a long mouse sweep takes the pointer off it.
    static let requestedSize = CGSize(width: 4000, height: 2600)

    // Settings (GameSettings pushes them).
    var enabled = true
    var recenterOnExit = true
    var fill: InputCatcherFill = .clear

    // State, for the view and GET /state.
    private(set) var isOpen = false
    private(set) var wanted = false
    private(set) var reason = "not started"
    private(set) var hovering = false
    private(set) var actualSize: CGSize?
    private(set) var opens = 0
    private(set) var recenters = 0
    private(set) var pinches = 0
    private(set) var autoFallbacks = 0
    private(set) var lastFinding: String?
    /// Bumped to ask the catcher's own view to dismiss its window.
    private(set) var closeRequests = 0

    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var dismissWindow: DismissWindowAction?
    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?

    // Lifecycle bookkeeping.
    @ObservationIgnored private var requestedOpenAt: TimeInterval?
    @ObservationIgnored private var openRequestsUnanswered = 0
    @ObservationIgnored private var dismissingOurselves = false
    @ObservationIgnored private var unwantedSince: TimeInterval?
    @ObservationIgnored private var lastStuckLogAt: TimeInterval = -.infinity
    @ObservationIgnored private var reopenNotBefore: TimeInterval = 0
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
            break
        case .moved:
            mouseEvents.record(at: now)
            mouseMoves.record(at: now)
            watch.mouseEvent(at: now)
        case .button, .scroll:
            mouseEvents.record(at: now)
            watch.mouseEvent(at: now)
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
        let decision = decide()
        if decision.reason != reason {
            AppLog.input.log("[InputCatcher] \(decision.wanted ? "wanted" : "not wanted", privacy: .public): \(decision.reason, privacy: .public)")
        }
        wanted = decision.wanted
        reason = decision.reason

        if wanted {
            unwantedSince = nil
            if isOpen {
                recenterIfPointerLeft(now: now)
                checkWatch(now: now)
            } else if now >= reopenNotBefore, requestedOpenAt.map({ now - $0 > 2 }) ?? true {
                open(now: now)
            }
        } else if isOpen || requestedOpenAt != nil {
            if isOpen {
                if unwantedSince == nil { unwantedSince = now }
                if let since = unwantedSince, now - since > 2, now - lastStuckLogAt > 10 {
                    lastStuckLogAt = now
                    AppLog.input.error("[InputCatcher] still up \(String(format: "%.0f", now - since), privacy: .public) s after asking it to close (\(self.reason, privacy: .public)); asking again")
                }
            }
            close()
        }
        logActivity(now: now)
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

    private func close() {
        requestedOpenAt = nil
        guard isOpen else { return }
        dismissingOurselves = true
        dismissWindow?(id: Self.windowID)
        // And from inside: works even if the main window's action doesn't.
        closeRequests += 1
    }

    private func recenterIfPointerLeft(now: TimeInterval) {
        guard recenterOnExit, !hovering, let ended = hoverEndedAt,
              now - ended >= Self.recenterDelay,
              now - lastRecenterAt >= Self.recenterMinInterval else { return }
        lastRecenterAt = now
        hoverEndedAt = nil
        recenters += 1
        AppLog.input.log("[InputCatcher] pointer left the catcher: re-centring (#\(self.recenters))")
        close()
        // Reopened by the next ticks, once the dismissal has landed.
        reopenNotBefore = now + 0.3
    }

    private func checkWatch(now: TimeInterval) {
        guard let finding = watch.check(now: now, catcherOpen: isOpen) else { return }
        lastFinding = finding.rawValue
        switch finding {
        case .pointerPassedCatcher:
            if fill == .clear {
                autoFallbacks += 1
                AppLog.input.error("[InputCatcher] a pointer event reached the immersive layer through the clear catcher: switching fill to faint (#\(self.autoFallbacks))")
                // Through the settings, so GET /settings and the toggle agree.
                if let settings = appModel?.gameSettings { settings.inputCatcherFill = .faint } else { fill = .faint }
            } else {
                AppLog.input.error("[InputCatcher] a pointer event reached the immersive layer with the catcher up (fill \(self.fill.rawValue, privacy: .public)): the pointer is off it or it doesn't catch")
            }
        case .pointerOnCatcherMouseSilent:
            AppLog.input.error("[InputCatcher] the pointer moves on the catcher but GCMouse is silent (fill \(self.fill.rawValue, privacy: .public)); try inputCatcherFill=faint or visible")
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
        AppLog.input.log("[InputCatcher] up: \(events) GCMouse events (\(moves) moves) in \(String(format: "%.1f", span), privacy: .public) s, pointer \(self.hovering ? "on" : "off", privacy: .public) the catcher, mode \(InputModeState.current.label, privacy: .public), fill \(self.fill.rawValue, privacy: .public)")
    }

    // MARK: From the window

    func windowAppeared() {
        isOpen = true
        requestedOpenAt = nil
        openRequestsUnanswered = 0
        hovering = false
        hoverEndedAt = nil
        lastHoverPoint = nil
        watch.reset()
        opens += 1
        lastLogAt = CACurrentMediaTime()
        eventsAtLastLog = mouseEvents.total
        movesAtLastLog = mouseMoves.total
        AppLog.input.log("[InputCatcher] window up (#\(self.opens), fill \(self.fill.rawValue, privacy: .public))")
    }

    func windowDisappeared() {
        guard isOpen else { return }
        isOpen = false
        hovering = false
        unwantedSince = nil
        if !dismissingOurselves {
            // Closed by the system or the player while we still want it.
            reopenNotBefore = CACurrentMediaTime() + Self.externalCloseBackoff
            AppLog.input.log("[InputCatcher] window closed from outside; reopening no sooner than \(Int(Self.externalCloseBackoff)) s")
        }
        dismissingOurselves = false
        AppLog.input.log("[InputCatcher] window down")
    }

    /// The catcher scene's phase. A window the system took away goes to the
    /// background, sometimes without `onDisappear`.
    func windowPhase(_ phase: ScenePhase) {
        AppLog.input.log("[InputCatcher] window scene phase \(String(describing: phase), privacy: .public)")
        switch phase {
        case .background: windowDisappeared()
        case .active where !isOpen: windowAppeared()
        default: break
        }
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

    // MARK: GET /state

    nonisolated struct Status: Encodable, Sendable {
        let enabled: Bool
        let wanted: Bool
        let open: Bool
        let reason: String
        let fill: String
        let recenterOnExit: Bool
        let pointerOnCatcher: Bool
        let sizePt: [Double]?
        let opens: Int
        let recenters: Int
        let pinches: Int
        let autoFallbacks: Int
        let lastFinding: String?
    }

    var status: Status {
        Status(enabled: enabled, wanted: wanted, open: isOpen, reason: reason, fill: fill.rawValue,
               recenterOnExit: recenterOnExit, pointerOnCatcher: hovering,
               sizePt: actualSize.map { [Double($0.width), Double($0.height)] },
               opens: opens, recenters: recenters, pinches: pinches,
               autoFallbacks: autoFallbacks, lastFinding: lastFinding)
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
            // Hit-testable everywhere even where nothing is drawn.
            .contentShape(Rectangle())
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

    @ViewBuilder private var fillView: some View {
        switch catcher.fill {
        case .clear:
            Color.clear
        case .faint:
            Color.white.opacity(0.003)
        case .visible:
            Rectangle()
                .fill(Color.cyan.opacity(0.08))
                .overlay(Rectangle().stroke(Color.cyan.opacity(0.6), lineWidth: 6))
                .overlay(Text("Mouse capture window").font(.largeTitle).foregroundStyle(.cyan.opacity(0.7)))
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
