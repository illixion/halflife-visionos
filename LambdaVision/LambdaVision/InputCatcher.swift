//
//  InputCatcher.swift
//  LambdaVision
//
//  A workaround prototype for the visionOS mouse-focus limit: GCMouse
//  delivers nothing while the pointer is in the full immersive space
//  (CompositorLayer) and not over one of the app's windows, and no API
//  claims the mouse for an immersive space (~/Memory: Projects
//  visionos-input-window-focus). But the system routes the mouse to the app
//  whenever the pointer is over one of its windows, and a window doesn't
//  need to show anything to count: a Convolution photo window that failed to
//  load, fully transparent and with its controls hidden, kept capturing the
//  mouse. So this is that window on purpose: a large plain window with no
//  glass, no content and no system controls, kept up in front of the player
//  while the game is played with a keyboard and mouse.
//
//  What it does to input:
//  - Mouse: nothing of its own. GCMouse (MouseInput, via RAVEMouseSource)
//    reads the device directly; the window only makes the system send the
//    events to this app. Its own pointer clicks (SwiftUI `.pointer` spatial
//    events) are dropped.
//  - Look-and-pinch: lands on the catcher instead of the immersive layer
//    wherever the catcher covers the view. It counts as the hands' bid for
//    the input mode, exactly as on the layer, and never fires: outside hands
//    mode a pinch doesn't fire anyway, and in the "mouse connected, waiting"
//    case the first pinch takes the catcher down.
//  - Gamepad: claimed like every other window (.handlesGameControllerEvents).
//
//  When it's up (InputCatcherRule): in game, immersive space open, no menu
//  or console, Settings › Keyboard, mouse & gamepad › "Mouse capture window"
//  on, and the mode is keyboard+mouse (or Auto with a mouse connected and no
//  hands bid since). The menu and console take it down because they're
//  driven by gaze-and-pinch, which the catcher would swallow.
//
//  Placement: visionOS gives an app no say. `defaultWindowPlacement` can
//  only place a window beside another of the app's windows (SwiftUI docs:
//  the system places the first window where the person is looking and
//  ignores a free placement), there's no head-following window, and
//  `windowManagerRole` has only `.automatic` on visionOS. A new window opens
//  in front of the player, so the catcher re-centres by reopening: when the
//  pointer leaves it (`onContinuousHover` .ended — pointer hover is reported
//  to apps, eye gaze is not), it is dismissed and opened again in front of
//  the player, at most every few seconds (Settings: "Re-centre when the
//  pointer leaves").
//
//  Diagnostics: every GCMouse event is counted (MouseInput → `recordMouse`);
//  GET /state carries `mouseEventsLastSecond` and an `inputCatcher` object,
//  and while the catcher is up a line is logged every few seconds with the
//  event count, so the headset can be checked remotely.
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
    private(set) var handBids = 0

    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var dismissWindow: DismissWindowAction?
    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?

    // Lifecycle bookkeeping.
    @ObservationIgnored private var requestedOpenAt: TimeInterval?
    @ObservationIgnored private var dismissingOurselves = false
    @ObservationIgnored private var reopenNotBefore: TimeInterval = 0
    @ObservationIgnored private var hoverEndedAt: TimeInterval?
    @ObservationIgnored private var lastRecenterAt: TimeInterval = -.infinity
    @ObservationIgnored private var warnedNoActions = false
    @ObservationIgnored private var bidPinches = Set<SpatialEventCollection.Event.ID>()

    // Mouse diagnostics (MouseInput, main queue).
    @ObservationIgnored private var mouseEvents = RollingRate()
    @ObservationIgnored private var mouseMoves = RollingRate()
    @ObservationIgnored private(set) var mouseConnectedAt: TimeInterval?
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

    /// Window actions from any window of the app; opening a window needs a
    /// SwiftUI action and the decision is made here, not in a view.
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
        case .connected:
            mouseConnectedAt = now
        case .disconnected:
            break
        case .moved:
            mouseEvents.record(at: now)
            mouseMoves.record(at: now)
        case .button, .scroll:
            mouseEvents.record(at: now)
        }
    }

    var mouseEventsLastSecond: Int { mouseEvents.lastSecond(at: CACurrentMediaTime()) }
    var mouseMovesLastSecond: Int { mouseMoves.lastSecond(at: CACurrentMediaTime()) }
    var mouseEventsTotal: Int { mouseEvents.total }
    var secondsSinceMouseEvent: Double? { mouseEvents.lastAt.map { CACurrentMediaTime() - $0 } }

    // MARK: The decision loop

    private func inputs(now: TimeInterval) -> InputCatcherInputs {
        let settings = appModel?.gameSettings
        let ready = settings?.isEngineReady ?? false
        return InputCatcherInputs(
            enabled: enabled,
            immersiveOpen: appModel?.immersiveSpaceState == .open,
            engineReady: ready,
            inGame: ready && lambda_debug_in_game() != 0,
            loading: ready && lambda_engine_loading() != 0,
            menuOpen: ready && lambda_menu_active() != 0,
            consoleOpen: ready && lambda_console_active() != 0,
            mode: InputModeState.current,
            setting: InputModeState.setting,
            mouseConnected: MouseInput.connected,
            mouseConnectedAt: mouseConnectedAt,
            lastHandsAt: InputModeState.lastUsed(.hands))
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let decision = InputCatcherRule.evaluate(inputs(now: now))
        if decision.reason != reason {
            AppLog.input.log("[InputCatcher] \(decision.wanted ? "wanted" : "not wanted", privacy: .public): \(decision.reason, privacy: .public)")
        }
        wanted = decision.wanted
        reason = decision.reason

        if wanted {
            if isOpen {
                recenterIfPointerLeft(now: now)
            } else if now >= reopenNotBefore, requestedOpenAt.map({ now - $0 > 2 }) ?? true {
                open(now: now)
            }
        } else if isOpen || requestedOpenAt != nil {
            close()
        }
        logActivity(now: now)
    }

    private func open(now: TimeInterval) {
        guard let openWindow else {
            if !warnedNoActions {
                warnedNoActions = true
                AppLog.input.error("[InputCatcher] can't open: no window has handed over its openWindow action yet")
            }
            return
        }
        requestedOpenAt = now
        openWindow(id: Self.windowID)
    }

    private func close() {
        requestedOpenAt = nil
        guard isOpen, let dismissWindow else { return }
        dismissingOurselves = true
        dismissWindow(id: Self.windowID)
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

    private func logActivity(now: TimeInterval) {
        guard isOpen, now - lastLogAt >= Self.logInterval else { return }
        let events = mouseEvents.total - eventsAtLastLog
        let moves = mouseMoves.total - movesAtLastLog
        let span = lastLogAt == 0 ? Self.logInterval : now - lastLogAt
        lastLogAt = now
        eventsAtLastLog = mouseEvents.total
        movesAtLastLog = mouseMoves.total
        AppLog.input.log("[InputCatcher] up: \(events) GCMouse events (\(moves) moves) in \(String(format: "%.1f", span), privacy: .public) s, pointer \(self.hovering ? "on" : "off", privacy: .public) the catcher, mode \(InputModeState.current.label, privacy: .public)")
    }

    // MARK: From the window

    func windowAppeared() {
        isOpen = true
        requestedOpenAt = nil
        hovering = false
        hoverEndedAt = nil
        opens += 1
        lastLogAt = CACurrentMediaTime()
        eventsAtLastLog = mouseEvents.total
        movesAtLastLog = mouseMoves.total
        AppLog.input.log("[InputCatcher] window up (#\(self.opens), fill \(self.fill.rawValue, privacy: .public))")
    }

    func windowDisappeared() {
        isOpen = false
        hovering = false
        if !dismissingOurselves {
            // Closed by the system or the player while we still want it.
            reopenNotBefore = CACurrentMediaTime() + Self.externalCloseBackoff
            AppLog.input.log("[InputCatcher] window closed from outside; reopening no sooner than \(Int(Self.externalCloseBackoff)) s")
        }
        dismissingOurselves = false
        AppLog.input.log("[InputCatcher] window down")
    }

    func sized(_ size: CGSize) {
        guard size != actualSize else { return }
        actualSize = size
        AppLog.input.log("[InputCatcher] window size \(Int(size.width))×\(Int(size.height)) pt (asked \(Int(Self.requestedSize.width))×\(Int(Self.requestedSize.height)))")
    }

    func hover(_ phase: HoverPhase) {
        switch phase {
        case .active:
            if !hovering { hoverEndedAt = nil }
            hovering = true
        case .ended:
            hovering = false
            hoverEndedAt = CACurrentMediaTime()
        }
    }

    /// Spatial events on the catcher. A look-and-pinch is the hands' bid for
    /// the input mode (once per pinch); pointer clicks are GCMouse's.
    func spatial(_ events: SpatialEventCollection) {
        for event in events {
            switch event.phase {
            case .active:
                guard event.kind == .indirectPinch || event.kind == .directPinch,
                      bidPinches.insert(event.id).inserted else { continue }
                handBids += 1
                InputModeState.deviceUsed(.hands, now: CACurrentMediaTime())
                AppLog.input.log("[InputCatcher] pinch on the catcher: hands bid (#\(self.handBids))")
            default:
                bidPinches.remove(event.id)
            }
        }
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
        let handBids: Int
    }

    var status: Status {
        Status(enabled: enabled, wanted: wanted, open: isOpen, reason: reason, fill: fill.rawValue,
               recenterOnExit: recenterOnExit, pointerOnCatcher: hovering,
               sizePt: actualSize.map { [Double($0.width), Double($0.height)] },
               opens: opens, recenters: recenters, handBids: handBids)
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

    var body: some View {
        fillView
            .frame(width: InputCatcher.requestedSize.width, height: InputCatcher.requestedSize.height)
            // Hit-testable everywhere even where nothing is drawn.
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { catcher.sized($0) }
            // No hover highlight anywhere in the window.
            .hoverEffectDisabled()
            .onContinuousHover { catcher.hover($0) }
            .gesture(SpatialEventGesture()
                .onChanged { catcher.spatial($0) }
                .onEnded { catcher.spatial($0) })
            // Hide the grabber and close button (and the window's ornaments).
            .persistentSystemOverlays(.hidden)
            .handlesGameControllerEvents(matching: .gamepad)
            .onAppear { catcher.windowAppeared() }
            .onDisappear { catcher.windowDisappeared() }
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
