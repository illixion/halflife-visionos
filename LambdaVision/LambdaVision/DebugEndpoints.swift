//
//  DebugEndpoints.swift
//  LambdaVision
//
//  The app's debug API: endpoints on DebugTrace's `DebugSurface.shared`, and
//  the server that serves them. One registration reaches three readers — the
//  HTTP server (`curl`), its MCP endpoint (the `apps` MCP entry agents use)
//  and the debug traces the Console window's trace button builds — so a
//  coordinator can take headset screenshots and read and drive the game
//  without a cable:
//
//      curl http://<device>:<port>/                          # self-describing index
//      curl http://<device>:<port>/state                     # map, player, HUD, input mode
//      curl -o shot.png "http://<device>:<port>/screenshot?eye=both"
//      curl -X POST "http://<device>:<port>/console?command=impulse%20101"
//
//  scripts/avp-screenshot.sh finds the server and saves a screenshot.
//  Transport, auth, argument validation, help and MCP are DebugTrace's
//  (~/Projects/DebugTrace); this file is the endpoint table and the server's
//  lifecycle.
//
//  When it serves (LambdaDebugServer): DebugTrace's rule — a development
//  build that build-and-sign signed, or a launch with DEBUGTRACE_SERVER=1
//  (`build-and-sign --mcp`) — unless Settings › Advanced › Debug server says
//  On (also an Xcode run) or Off (not even a signed build; an explicit
//  DEBUGTRACE_SERVER=1 launch still wins). Never in an App Store or
//  TestFlight build. Build with LAMBDA_NO_DEBUG_SERVER to compile the server
//  out (the endpoints stay, for traces).
//
//  Ports: 8651–8691, the top of DebugTrace's range. The Wi-Fi manager takes
//  8642 and falls back through 8650 (GameLibraryServer), so the two never
//  race for a port. Clients never hard-code it: the server logs "listening
//  on port N" and `bas --mcp` records it.
//

import DebugTrace
import Foundation
import GameLibrary
import QuartzCore
import RAVEDiagnostics
import SwiftUI
#if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
import DebugTraceServer
import Network
import os
import UIKit
#endif

/// Settings › Advanced › Debug server.
nonisolated enum DebugServerMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .on: "On"
        case .off: "Off"
        }
    }
}

// MARK: - Server lifecycle

@MainActor
enum LambdaDebugServer {
    static let ports: ClosedRange<UInt16> = 8651...8691

    /// Whether this build can serve at all (development privacy, and the
    /// server compiled in). Settings hides the row otherwise.
    static var available: Bool {
        #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
        DebugTrace.privacy == .development
        #else
        false
        #endif
    }

    #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
    private static var server: DebugTraceServer?
    #endif

    static var isRunning: Bool {
        #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
        server?.isRunning ?? false
        #else
        false
        #endif
    }

    static var port: Int? {
        #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
        server?.port.map(Int.init)
        #else
        nil
        #endif
    }

    /// Whether `mode` wants a server for this launch.
    static func wanted(_ mode: DebugServerMode) -> Bool {
        #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
        guard DebugTrace.privacy == .development else { return false }
        let explicit = ProcessInfo.processInfo.environment["DEBUGTRACE_SERVER"]
        switch mode {
        case .automatic: return DebugTraceServer.requestedAtLaunch
        case .on: return explicit != "0"
        case .off: return explicit == "1"
        }
        #else
        return false
        #endif
    }

    /// Starts or stops the server to match `mode`. Called at launch and when
    /// the setting changes.
    static func apply(_ mode: DebugServerMode) {
        #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
        if wanted(mode) {
            if server == nil { start(reason: "setting \(mode.rawValue)") }
            startWatching()
        } else {
            stopWatching()
            if let s = server {
                s.stop()
                server = nil
                AppLog.app.log("[DebugServer] stopped (setting \(mode.rawValue, privacy: .public))")
            }
        }
        #endif
    }

    #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER

    // MARK: Keeping it alive
    //
    // DebugTraceServer watches its NWListener's state only until the first
    // `.ready`: a later `.failed` / `.cancelled` (a defuncted socket, a
    // Bonjour registration failure on a network change) is swallowed, and the
    // server still reports `isRunning` with its old port while every
    // connection is refused. On the headset that happened ~6 minutes into a
    // session, with nothing logged (2026-10-06). The listener is private, so
    // from out here the only way to see that is to knock: every few seconds
    // the watchdog connects to the port over loopback and over the Wi-Fi
    // address, and rebuilds the server — on the same port when it can, so a
    // client's recorded URL keeps working — when the knock is refused. Path
    // changes, app lifecycle and scene phases are logged alongside, so the
    // log says what the listener died next to.

    /// The port the last server bound; a restart tries it first.
    private static var lastPort: UInt16?
    private static var watchdog: Task<Void, Never>?
    private static var pathMonitor: NWPathMonitor?
    private static var lifecycleObservers: [NSObjectProtocol] = []
    private static var restarts = 0
    static let checkInterval: Duration = .seconds(5)

    private static func makeServer(ports range: ClosedRange<UInt16>) -> DebugTraceServer {
        // The default `.ask` prompts in DebugTraceUI's DebugApprovalWindow
        // (LambdaVisionApp): over the immersive space there is no UIKit window
        // for a system alert.
        DebugTraceServer(configuration: .init(ports: range))
    }

    private static func start(reason: String) {
        let preferred = lastPort.map { $0...ports.upperBound } ?? ports
        let s = makeServer(ports: preferred)
        server = s
        AppLog.app.log("[DebugServer] starting (\(reason, privacy: .public)), ports \(preferred.lowerBound)-\(preferred.upperBound)")
        Task { @MainActor in
            do {
                lastPort = try await s.start()
            } catch {
                guard server === s else { return }
                // The preferred port range is all taken: the whole range.
                if preferred != ports {
                    let full = makeServer(ports: ports)
                    server = full
                    if let p = try? await full.start() { lastPort = p; return }
                }
                AppLog.app.error("[DebugServer] could not start: \(String(describing: error), privacy: .public); retrying in \(checkInterval.components.seconds) s")
                server = nil
            }
        }
    }

    /// Relistens with the same server whose listener no longer answers. Same
    /// instance, not a new one: approvals live on the server, so a fresh
    /// instance asked "Allow debug access?" again right after a suspension,
    /// when nobody could answer, and every request hung on it. DebugTrace now
    /// also relistens on its own after a post-start failure; whichever runs
    /// second finds the listener already up and does nothing.
    private static func restart(reason: String) {
        restarts += 1
        AppLog.app.error("[DebugServer] listener on port \(lastPort.map(String.init) ?? "?", privacy: .public) stopped answering (\(reason, privacy: .public)); restart #\(restarts)")
        guard let s = server else { start(reason: "restart #\(restarts)"); return }
        s.stop()
        Task { @MainActor in
            do {
                lastPort = try await s.start()
                AppLog.app.log("[DebugServer] listening again on port \(lastPort.map(String.init) ?? "?", privacy: .public) (restart #\(restarts))")
            } catch {
                AppLog.app.error("[DebugServer] relisten failed: \(String(describing: error), privacy: .public); retrying in \(checkInterval.components.seconds) s")
                if server === s { server = nil }
            }
        }
    }

    /// One health check now (also run when the app comes back to the
    /// foreground, see `scenePhaseChanged`).
    static func check() async {
        guard watchdog != nil else { return }
        guard let s = server else { start(reason: "not running"); return }
        guard let port = s.port else { return }   // still binding
        var targets = ["127.0.0.1"]
        if let lan = DebugTraceServer.localAddresses().first(where: { $0.hasPrefix("en") })?.split(separator: " ").last {
            targets.append(String(lan))
        }
        for host in targets {
            let outcome = await ListenerProbe.knock(host: host, port: port)
            guard server === s else { return }    // replaced meanwhile
            switch outcome {
            case .accepted: continue
            case .refused(let why): restart(reason: "\(host):\(port) refused: \(why)"); return
            case .noAnswer(let why):
                // Not proof on its own (a stalled network); a second miss is.
                let again = await ListenerProbe.knock(host: host, port: port)
                guard server === s else { return }
                if case .accepted = again { continue }
                restart(reason: "\(host):\(port) no answer twice: \(why)")
                return
            }
        }
    }

    private static func startWatching() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: checkInterval)
                if Task.isCancelled { break }
                await check()
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces.map { "\($0.name)" }.joined(separator: ",")
            AppLog.app.log("[DebugServer] network path \(String(describing: path.status), privacy: .public) via \(interfaces, privacy: .public)")
        }
        monitor.start(queue: DispatchQueue(label: "LambdaVision.DebugServer.path"))
        pathMonitor = monitor
        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "entered background"),
            (UIApplication.willEnterForegroundNotification, "entering foreground"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory warning"),
        ]
        lifecycleObservers = events.map { name, label in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                AppLog.app.log("[DebugServer] app \(label, privacy: .public)")
            }
        }
    }

    private static func stopWatching() {
        watchdog?.cancel()
        watchdog = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
    }
    #endif

    /// Logged, and back to `.active` re-checks the listener at once: a
    /// suspension defuncts listening sockets.
    static func scenePhaseChanged(_ phase: ScenePhase) {
        #if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
        guard server != nil || watchdog != nil else { return }
        AppLog.app.log("[DebugServer] scene phase \(String(describing: phase), privacy: .public)")
        if phase == .active { Task { await check() } }
        #endif
    }
}

#if canImport(DebugTraceServer) && !LAMBDA_NO_DEBUG_SERVER
/// A TCP connect to the server's own port, closed at once: the kernel
/// accepts it if a listener is bound, whatever the main actor is doing, so a
/// refusal means the listener is gone. Sends nothing (the server cancels a
/// connection that closes before a request).
nonisolated enum ListenerProbe {
    enum Outcome: Sendable { case accepted, refused(String), noAnswer(String) }

    static func knock(host: String, port: UInt16, timeout: Double = 2) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .refused("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "LambdaVision.DebugServer.probe")
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ outcome: Outcome) {
                guard once.withLock({ let first = !$0; $0 = true; return first }) else { return }
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.accepted)
                case .failed(let error): finish(Self.classify(error))
                case .waiting(let error): finish(Self.classify(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.noAnswer("no reply in \(timeout) s")) }
        }
    }

    private static func classify(_ error: NWError) -> Outcome {
        if case .posix(let code) = error, code == .ECONNREFUSED || code == .ECONNRESET {
            return .refused(String(describing: error))
        }
        return .noAnswer(String(describing: error))
    }
}
#endif

// MARK: - Endpoints

@MainActor
enum DebugEndpoints {
    private static weak var appModel: AppModel?
    private static var openImmersive: (@MainActor () async -> Bool)?
    private static var dismissImmersive: (@MainActor () async -> Void)?
    private static var registered = false

    /// Registers the table on `DebugSurface.shared`. Called from the main
    /// window (it owns the immersive-space actions); safe to call again.
    static func register(appModel: AppModel,
                         openImmersive: @escaping @MainActor () async -> Bool,
                         dismissImmersive: @escaping @MainActor () async -> Void) {
        self.appModel = appModel
        self.openImmersive = openImmersive
        self.dismissImmersive = dismissImmersive
        guard !registered else { return }
        registered = true
        DebugSurface.shared.register(endpoints())
    }

    // MARK: Helpers

    private static func model() throws(DebugError) -> AppModel {
        guard let appModel else {
            throw .unavailable("the app model is gone", hint: "the main window is closing; relaunch the app")
        }
        return appModel
    }

    private static let notStarted = "open the immersive space (POST /immersive?open=true, or Show Immersive Space in the main window), then poll GET /state until engineReady is true"

    /// Console text the engine must see as one command: no separators,
    /// quotes or line breaks smuggled in through an argument.
    private static func plainToken(_ value: String, _ name: String, endpoint: String) throws(DebugError) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.+"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw .invalidArgument("'\(name)' of '\(endpoint)' must be letters, digits, _ - . or +; got '\(value)'",
                                   hint: "pass one bare word, e.g. \(endpoint == "map" ? "c1a0" : "sv_cheats")")
        }
        return value
    }

    private static func send(_ command: String) {
        _ = command.withCString { lambda_gl_worker_cmd($0) }
    }

    static func cvar(_ name: String) -> String? {
        var buf = [CChar](repeating: 0, count: 512)
        let exists = buf.withUnsafeMutableBufferPointer { lambda_debug_cvar(name, $0.baseAddress, Int32($0.count)) }
        guard exists != 0 else { return nil }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The loaded map, from `cl_levelshot_name` ("levelshots/<map>_16x9"),
    /// which the client sets on every map load, changelevel included.
    static func mapName() -> String? {
        guard lambda_debug_in_game() != 0, var shot = cvar("cl_levelshot_name"),
              shot.hasPrefix("levelshots/") else { return nil }
        shot.removeFirst("levelshots/".count)
        for suffix in ["_16x9", "_4x3"] where shot.hasSuffix(suffix) { shot.removeLast(suffix.count) }
        return shot.isEmpty ? nil : shot
    }

    // MARK: Replies

    private nonisolated struct Vec3: Encodable, Sendable { let x: Float, y: Float, z: Float }

    private nonisolated struct StateReply: Encodable, Sendable {
        struct Game: Encodable, Sendable { let gamedir: String; let title: String; let kind: String }
        struct Input: Encodable, Sendable { let current: String; let setting: String }
        struct Player: Encodable, Sendable {
            let viewOrigin: Vec3            // world units, the last rendered eye
            let viewAnglesDeg: Vec3         // x pitch (+ down), y yaw, z roll
            let velocityUnitsPerSec: Vec3   // x forward, y left, z up (player-yaw frame)
            let groundSpeedUnitsPerSec: Float
            let onGround: Bool
            let waterLevel: Int             // 0 dry … 3 submerged
            let eyeHeightUnits: Float
        }
        struct HUD: Encodable, Sendable {
            let hasSuit: Bool
            let health: Int
            let battery: Int
            let weaponId: Int               // -1 none
            let clip: Int                   // -1 not applicable
            let maxClip: Int
            let ammo1: Int
            let ammo1Max: Int
            let ammo2: Int
            let ammo2Max: Int
            let flashlightOn: Bool
            let flashlightCharge: Float
            let intermission: Bool
            let hideFlags: Int
        }
        struct Frames: Encodable, Sendable {
            let lastFrameAgoMs: Double?
            let lastCapture: FrameCapture.Info?
        }
        let engineReady: Bool
        let immersiveSpace: String
        let preparing: Bool
        let inGame: Bool
        let loading: Bool
        let menuOpen: Bool
        let consoleOpen: Bool
        let map: String?
        let runningGame: Game?
        let selectedGame: String?
        let inputMode: Input
        let weaponDrawn: Bool
        let player: Player?
        let hud: HUD?
        let frames: Frames
        let debugServerPort: Int?
        let mouseConnected: Bool
        /// GCMouse events (moves, buttons, wheel) in the last second.
        let mouseEventsLastSecond: Int
        let mouseMovesLastSecond: Int
        let mouseEventsTotal: Int
        let lastMouseEventAgoMs: Double?
        let inputCatcher: InputCatcher.Status
        /// Free aim (keyboard/mouse/gamepad): the aim offset in its zone, the
        /// overflow turning the body, the anchor, and what the engine got.
        let freeAim: Renderer.FreeAimStatus
    }

    static func stateReply() throws(DebugError) -> some Encodable & Sendable {
        let app = try model()
        let ready = app.gameSettings.isEngineReady
        let inGame = ready && lambda_debug_in_game() != 0
        var player: StateReply.Player?
        var hud: StateReply.HUD?
        if inGame {
            var origin: [Float] = [0, 0, 0], angles: [Float] = [0, 0, 0]
            _ = origin.withUnsafeMutableBufferPointer { o in
                angles.withUnsafeMutableBufferPointer { a in lambda_debug_view(o.baseAddress, a.baseAddress) }
            }
            var body = lambda_body_state_t()
            lambda_body_state(&body)
            let v = body.velocity
            player = .init(viewOrigin: Vec3(x: origin[0], y: origin[1], z: origin[2]),
                           viewAnglesDeg: Vec3(x: angles[0], y: angles[1], z: angles[2]),
                           velocityUnitsPerSec: Vec3(x: v.0, y: v.1, z: v.2),
                           groundSpeedUnitsPerSec: (v.0 * v.0 + v.1 * v.1).squareRoot(),
                           onGround: body.on_ground != 0, waterLevel: Int(body.water_level),
                           eyeHeightUnits: body.eye_height)
            var h = lambda_hud_state_t()
            lambda_hud_state(&h)
            hud = .init(hasSuit: h.has_suit != 0, health: Int(h.health), battery: Int(h.battery),
                        weaponId: Int(h.weapon_id), clip: Int(h.clip), maxClip: Int(h.max_clip),
                        ammo1: Int(h.ammo1), ammo1Max: Int(h.ammo1_max), ammo2: Int(h.ammo2), ammo2Max: Int(h.ammo2_max),
                        flashlightOn: h.flashlight_on != 0, flashlightCharge: h.flashlight_charge,
                        intermission: h.intermission != 0, hideFlags: Int(h.hide_flags))
        }
        let running = GameData.runningGame
        let space: String = switch app.immersiveSpaceState {
        case .open: "open"
        case .closed: "closed"
        case .inTransition: "inTransition"
        }
        return StateReply(
            engineReady: ready, immersiveSpace: space, preparing: app.isPreparing, inGame: inGame,
            loading: ready && lambda_engine_loading() != 0,
            menuOpen: ready && lambda_menu_active() != 0, consoleOpen: ready && lambda_console_active() != 0,
            map: ready ? mapName() : nil,
            runningGame: running.map { .init(gamedir: $0.gamedir, title: $0.title, kind: String(describing: $0.kind)) },
            selectedGame: app.library.selectedGame?.gamedir,
            inputMode: .init(current: InputModeState.current.rawValue, setting: InputModeState.setting.rawValue),
            weaponDrawn: inGame && lambda_weapon_active() != 0,
            player: player, hud: hud,
            frames: .init(lastFrameAgoMs: FrameCapture.shared.secondsSinceLastFrame.map { $0 * 1000 },
                          lastCapture: FrameCapture.shared.lastInfo),
            debugServerPort: LambdaDebugServer.port,
            mouseConnected: MouseInput.connected,
            mouseEventsLastSecond: InputCatcher.shared.mouseEventsLastSecond,
            mouseMovesLastSecond: InputCatcher.shared.mouseMovesLastSecond,
            mouseEventsTotal: InputCatcher.shared.mouseEventsTotal,
            lastMouseEventAgoMs: InputCatcher.shared.secondsSinceMouseEvent.map { $0 * 1000 },
            inputCatcher: InputCatcher.shared.status,
            freeAim: Renderer.freeAimStatus)
    }

    // MARK: Settings table

    /// One Settings value, read and written through GameSettings so a change
    /// persists, applies, and shows in the Settings window like a tap would.
    /// Add a row here when adding a setting.
    private struct Setting {
        let key: String
        let kind: String
        let choices: [String]?
        let range: ClosedRange<Double>?
        let note: String?
        let get: @MainActor (GameSettings) -> JSONValue
        let set: @MainActor (GameSettings, String) throws -> Void

        static func number(_ key: String, _ path: ReferenceWritableKeyPath<GameSettings, Double>,
                           _ range: ClosedRange<Double>, note: String? = nil) -> Setting {
            Setting(key: key, kind: "number", choices: nil, range: range, note: note,
                    get: { .double($0[keyPath: path]) },
                    set: { settings, text in
                        guard let v = Double(text), range.contains(v) else {
                            throw DebugError.invalidArgument("'\(key)' takes a number in \(range.lowerBound)…\(range.upperBound); got '\(text)'",
                                                   hint: "GET /settings shows each key's current value and range")
                        }
                        settings[keyPath: path] = v
                    })
        }

        static func flag(_ key: String, _ path: ReferenceWritableKeyPath<GameSettings, Bool>, note: String? = nil) -> Setting {
            Setting(key: key, kind: "boolean", choices: ["true", "false"], range: nil, note: note,
                    get: { .bool($0[keyPath: path]) },
                    set: { settings, text in
                        switch text.lowercased() {
                        case "1", "true", "on", "yes": settings[keyPath: path] = true
                        case "0", "false", "off", "no": settings[keyPath: path] = false
                        default: throw DebugError.invalidArgument("'\(key)' takes true or false; got '\(text)'", hint: "value=true or value=false")
                        }
                    })
        }

        static func choice<E: CaseIterable & Equatable>(_ key: String, _ path: ReferenceWritableKeyPath<GameSettings, E>,
                                                        note: String? = nil) -> Setting {
            let names = E.allCases.map { String(describing: $0) }
            return Setting(key: key, kind: "choice", choices: names, range: nil, note: note,
                           get: { .string(String(describing: $0[keyPath: path])) },
                           set: { settings, text in
                               guard let value = E.allCases.first(where: { String(describing: $0) == text }) else {
                                   throw DebugError.invalidArgument("'\(key)' must be one of \(names.joined(separator: ", ")); got '\(text)'",
                                                          hint: DebugSuggest.closest(to: text, in: names).map { "did you mean '\($0)'?" })
                               }
                               settings[keyPath: path] = value
                           })
        }
    }

    private static let settingsTable: [Setting] = [
        // Graphics
        .number("renderScale", \.renderScale, 0.5...1, note: "applies when the immersive space next opens"),
        .flag("fxaaEnabled", \.fxaaEnabled),
        .flag("linearColor", \.linearColor),
        .flag("reprojectionDepth", \.reprojectionDepth),
        .flag("glassReflections", \.glassReflections),
        .flag("waterReflections", \.waterReflections),
        .flag("sharpWaterReflections", \.sharpWaterReflections),
        .number("waterRipples", \.waterRipples, 0...3),
        .number("reflectionStrength", \.reflectionStrength, 0.5...4),
        .choice("waterMirrorView", \.waterMirrorView, note: "not stored; needs waterReflections + sharpWaterReflections"),
        .number("waterUnderside", \.waterUnderside, 0...1, note: "not stored; sharp water: an object's underside as a share of its top's brightness, 0 = probe"),
        .choice("hdrTest", \.hdrTest, note: "not stored"),
        .flag("gpuPassTiming", \.gpuPassTiming, note: "not stored; fills the gpu columns of GET /perf"),
        .number("gamma", \.gamma, 1.8...3.6),
        .number("brightness", \.brightness, 0...1),
        .number("snapTurnDegrees", \.snapTurnDegrees, 15...45),
        // Audio
        .number("sfxVolume", \.sfxVolume, 0...1),
        .number("musicVolume", \.musicVolume, 0...1),
        // Input
        .choice("dominantHand", \.dominantHand),
        .choice("fireAimMode", \.fireAimMode),
        .flag("flashlightOnGun", \.flashlightOnGun),
        .flag("gestureInputEnabled", \.gestureInputEnabled),
        .flag("armSwingEnabled", \.armSwingEnabled),
        .choice("armSwingDirection", \.armSwingDirection),
        .number("armSwingSensitivity", \.armSwingSensitivity, 0.5...2),
        .flag("handLongJump", \.handLongJump),
        .flag("wheelUtilities", \.wheelUtilities),
        .flag("altFireGesture", \.altFireGesture),
        .number("altFireSensitivity", \.altFireSensitivity, 0.5...2),
        .flag("fastWeaponSwitch", \.fastWeaponSwitch),
        .flag("weaponExternal", \.weaponExternal),
        .flag("avatarBody", \.avatarBody),
        .flag("avatarLegs", \.avatarLegs),
        .flag("hevHUD", \.hevHUD),
        .choice("aimReticle", \.aimReticle),
        .choice("flatHUDPlacement", \.flatHUDPlacement),
        .flag("developerMode", \.developerMode),
        .choice("weaponModel", \.weaponModel),
        // Keyboard, mouse and gamepad
        .choice("inputMode", \.inputMode),
        .number("mouseSensitivity", \.mouseSensitivity, 0.5...10),
        .flag("stickSmoothTurn", \.stickSmoothTurn),
        .number("stickTurnSpeed", \.stickTurnSpeed, 45...240),
        .flag("lookPitch", \.lookPitch),
        .flag("freeAim", \.freeAim, note: "keyboard/mouse/gamepad: the mouse and right stick swing the gun inside a zone and only the excess turns the body; false = they turn the view as before. GET /state › freeAim"),
        .number("freeAimYaw", \.freeAimYaw, 0...45, note: "the zone's half-width, degrees; 0 = every bit of mouse yaw turns the body"),
        .number("freeAimPitch", \.freeAimPitch, 0...35, note: "the zone's half-height, degrees; excess pitch is clamped (tilts the view with lookPitch)"),
        .choice("freeAimShape", \.freeAimShape, note: "ellipse narrows toward its corners; rectangle doesn't"),
        .choice("freeAimAnchor", \.freeAimAnchor, note: "body: the zone stays ahead of the body while the head looks around; head: it follows the head's yaw lazily (freeAimFollow)"),
        .number("freeAimFollow", \.freeAimFollow, 0.1...1.5, note: "head anchor: the follow's time constant, seconds"),
        .flag("freeAimRecenter", \.freeAimRecenter, note: "ease the aim back to the zone's centre while the mouse and stick rest"),
        .number("freeAimRecenterTime", \.freeAimRecenterTime, 0.2...3, note: "the recentre's time constant, seconds"),
        .choice("freeAimPivot", \.freeAimPivot, note: "what the swung viewmodel turns about: shoulder, its grip hand, or the eye"),
        .flag("freeAimUse", \.freeAimUse, note: "+use picks what the gun points at (true) or the view's centre (false)"),
        .flag("hideParkedParts", \.hideParkedParts),
        .flag("inputCatcher", \.inputCatcher, note: "the invisible mouse-capture window; GET /state › inputCatcher and mouseEventsLastSecond show its effect"),
        .flag("inputCatcherAskBeforeLock", \.inputCatcherAskBeforeLock, note: "show the 'Click to lock mouse' prompt before the catcher (GET /state › inputCatcher.phase: idle / prompt / locked); off = the catcher opens directly"),
        .flag("inputCatcherRecenter", \.inputCatcherRecenter, note: "reopen the catcher in front of the player when the pointer leaves it"),
        .number("inputCatcherAlpha", \.inputCatcherAlpha, 0...0.2, note: "the catcher's fill opacity; the pointer ignores undrawn pixels. The catcher steps its effective alpha up on its own when GCMouse stays silent (GET /state › inputCatcher.effectiveAlpha)"),
        .choice("inputCatcherTechnique", \.inputCatcherTechnique, note: "how the catcher fills its window: swiftuiFill (white at inputCatcherAlpha), uiview (clear UIView, UIKit hover counted), metalEmpty (MTKView that never draws: the Convolution case), metalClear (one cleared drawable), realityTarget (invisible RealityKit input target)"),
        .flag("inputCatcherOutline", \.inputCatcherOutline, note: "not stored; draw the catcher's outline and label to see where it is"),
        .flag("inputCatcherMaterial", \.inputCatcherMaterial, note: "not stored; fill with .ultraThinMaterial at inputCatcherAlpha instead of white"),
        .flag("inputCatcherAutoStep", \.inputCatcherAutoStep, note: "not stored; false draws exactly inputCatcherAlpha (no automatic step-up when GCMouse is silent)"),
    ]

    private static func settingsReply(_ settings: GameSettings) -> JSONValue {
        var values: [String: JSONValue] = [:]
        var schema: [String: JSONValue] = [:]
        for s in settingsTable {
            values[s.key] = s.get(settings)
            var entry: [String: JSONValue] = ["kind": .string(s.kind)]
            if let choices = s.choices { entry["choices"] = .array(choices.map(JSONValue.string)) }
            if let range = s.range { entry["minimum"] = .double(range.lowerBound); entry["maximum"] = .double(range.upperBound) }
            if let note = s.note { entry["note"] = .string(note) }
            schema[s.key] = .object(entry)
        }
        return .object(["values": .object(values), "schema": .object(schema)])
    }

    // MARK: Perf and diagnostics

    private static func perfReply() -> JSONValue {
        let snapshot = FrameTimingStats.liveSnapshot()
        func columns(_ keys: [String]) -> JSONValue {
            var out: [String: JSONValue] = [:]
            for key in keys {
                guard let s = snapshot[key] else { continue }
                out[key] = .object(["p50Ms": .double(s.p50), "p95Ms": .double(s.p95), "p99Ms": .double(s.p99),
                                    "maxMs": .double(s.max), "meanMs": .double(s.mean), "peakMs": .double(s.peak),
                                    "samples": .int(s.count)])
            }
            return .object(out)
        }
        let appKeys = ["wait0", "wait1", "eyes", "angleGPU", "frameGPU", "total"]
        var reply: [String: JSONValue] = [
            "app": columns(appKeys),
            "gpu": columns(FrameTimingStats.gpuOrder),
            "gpuPassTiming": .bool(GPUPassTimer.enabled),
            "windowFrames": 512,
            "note": "app columns are CPU-observed latencies (the [FT] app(ms) log line); gpu columns are GPU execution (gpuQueue always, the rest with gpuPassTiming on — POST /setting?key=gpuPassTiming&value=true)",
        ]
        if let total = snapshot["total"], total.p50 > 0 { reply["fpsFromTotalP50"] = .double(1000 / total.p50) }
        return .object(reply)
    }

    private static func diagnosticsReply() -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for child in Mirror(reflecting: Renderer.aimDiag).children {
            guard let label = child.label else { continue }
            fields[label] = JSONValue(any: child.value)
        }
        return .object(["lines": .array(Renderer.aimDiagLines().map(JSONValue.string)), "fields": .object(fields)])
    }

    // MARK: Commands

    /// Waits up to `seconds` for `done`, polling every 50 ms on the main actor.
    private static func waitFor(_ seconds: Double, _ done: @MainActor () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private static func requireEngine() throws(DebugError) -> AppModel {
        let app = try model()
        guard app.gameSettings.isEngineReady else {
            // lambda_gl_worker_cmd before the GL worker exists is the
            // deadlock the settings_window memory warns about.
            throw .failedPrecondition("the engine has not started yet", hint: notStarted)
        }
        return app
    }

    // MARK: The table

    private static func endpoints() -> [DebugEndpoint] {
        let eyes = FrameCapture.Eye.allCases.map(\.rawValue)
        let sources = FrameCapture.Source.allCases.map(\.rawValue)
        return [
            // Queries
            .query("state", "Start here. Engine and immersive-space state, the loaded map and game, input mode, the player's view origin, view angles and velocity, the HEV HUD values (health, armor, weapon, ammo), the last frame / capture, and the mouse: GCMouse events in the last second (mouseEventsLastSecond) and the invisible mouse-capture window (inputCatcher), and free aim (freeAim: offset in the zone, overflow turning, anchor, the engine aim offset).",
                   releaseSafe: true) { _ in
                try stateReply()
            },
            .raw("screenshot", kind: .query,
                 "PNG of the next rendered frame, as the player sees it: the drawable after every pass the app encodes (engine composite, arms, gun, body, HEV holograms), unwarped from foveation to its logical size. eye=both puts the eyes side by side (left first) for stereo checks. source=engine reads the engine's colour map alone. Returns image/png, not JSON: curl -o shot.png. Needs the immersive space open.",
                 parameters: [
                     .string("eye", "which eye: left, right, or both side by side", default: "both", choices: eyes),
                     .string("source", "composited = the drawable with every Metal overlay; engine = the engine's colour map alone (no gun, body or holograms, no foveation)",
                             default: "composited", choices: sources),
                     .integer("width", "cap on the PNG's width in pixels for the whole picture, aspect kept; 0 = native (logical) resolution, large", default: 1600, range: 0...16384),
                     .boolean("unwarp", "undo the drawable's foveation (false = the physical, centre-magnified layout the GPU stored)", default: true),
                 ],
                 trace: .never, timeout: .seconds(20)) { args in
                var request = FrameCapture.Request()
                request.eye = FrameCapture.Eye(rawValue: args.string("eye") ?? "both") ?? .both
                request.source = FrameCapture.Source(rawValue: args.string("source") ?? "composited") ?? .composited
                request.maxWidth = args.int("width") ?? 1600
                request.unwarp = args.bool("unwarp") ?? true
                do throws(FrameCapture.Failure) {
                    let png = try await FrameCapture.shared.capture(request)
                    return .binary(png, contentType: "image/png", filename: "frame-\(request.eye.rawValue).png")
                } catch {
                    switch error {
                    case .noFrames:
                        throw DebugError.failedPrecondition("no frame rendered in the last second: the immersive space is closed, paused or still opening",
                                                            hint: "POST /immersive?open=true, wait until GET /state shows immersiveSpace open, then retry")
                    case .timeout:
                        throw DebugError(.timeout, "no frame picked the capture up within 5 s", hint: "GET /state: frames.lastFrameAgoMs says whether the renderer is drawing; retry once it is")
                    case .unsupported(let why):
                        throw DebugError.failedPrecondition(why, hint: request.source == .engine ? "retry with source=composited"
                                                            : "retry with source=engine (the engine image without the Metal overlays)")
                    case .encodeFailed:
                        throw DebugError(.internal, "PNG encoding failed", hint: "retry with a smaller width")
                    }
                }
            },
            .query("settings", "Every Settings value by key, with its kind, choices or range. Change one with POST /setting.",
                   releaseSafe: true) { _ in
                settingsReply(try model().gameSettings)
            },
            .query("perf", "Frame timing over the last 512 frames (p50/p95/p99/max per column): the app's [FT] CPU-observed stages and the GPU execution columns (GPUPassTimer).",
                   releaseSafe: true) { _ in
                perfReply()
            },
            .query("diagnostics", "The live input diagnostics the main window's Diagnostics section shows: aim source and offset, hand-sample gates, finger-gun, reload, alt-fire, weapon wheel, joystick, arm swing, ground speed. `lines` as shown, `fields` raw.") { _ in
                diagnosticsReply()
            },
            .query("cvar", "One engine cvar's current value.",
                   parameters: [.string("name", "the cvar, e.g. sv_cheats, r_vrglass, developer", required: true)]) { args in
                _ = try requireEngine()
                let name = try plainToken(try args.requireString("name"), "name", endpoint: "cvar")
                return ["name": JSONValue.string(name), "exists": .bool(cvar(name) != nil),
                        "value": cvar(name).map(JSONValue.string) ?? .null]
            },

            // Commands
            .command("console", "Run a console command on the GL worker, between frames, as if typed at the engine console (e.g. `impulse 101`, `god`, `give weapon_crossbow`, `menu_main`). Its printed output is not returned: read effects with GET /state, /cvar or /screenshot. Refused until the engine runs.",
                     parameters: [.string("command", "the console line; ';' separates several", required: true)]) { args in
                let app = try requireEngine()
                let command = try args.requireString("command").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, !command.contains("\n"), !command.contains("\r") else {
                    throw DebugError.invalidArgument("'command' must be one non-empty line", hint: "join several commands with ';'")
                }
                AppLog.app.log("[DebugServer] console: \(command)")
                app.gameSettings.command(command)
                // Executed from the engine's command buffer on its next
                // frames: give it a few before reporting the state.
                try? await Task.sleep(for: .milliseconds(150))
                return ["ran": JSONValue.string(command), "state": try JSONValue(encoding: stateReply())]
            },
            .command("setCvar", "Set an engine cvar, or toggle it between 0 and 1 when value is omitted. Returns the previous and resulting value.",
                     parameters: [
                         .string("name", "the cvar, e.g. r_vrglass", required: true),
                         .string("value", "the new value; omitted = toggle (non-zero → 0, zero → 1)"),
                     ]) { args in
                _ = try requireEngine()
                let name = try plainToken(try args.requireString("name"), "name", endpoint: "setCvar")
                guard let previous = cvar(name) else {
                    throw DebugError(.notFound, "no cvar named '\(name)'", hint: "check the spelling; cvars appear once the code registering them has run (e.g. a map is loaded)")
                }
                let value: String
                if let given = args.string("value") {
                    value = try plainToken(given, "value", endpoint: "setCvar")
                } else {
                    value = (Double(previous) ?? 0) != 0 ? "0" : "1"
                }
                send("\(name) \"\(value)\"")
                let applied = await waitFor(1) { cvar(name) == value || Double(cvar(name) ?? "") == Double(value) }
                return ["name": JSONValue.string(name), "previous": .string(previous),
                        "value": cvar(name).map(JSONValue.string) ?? .null, "applied": .bool(applied)]
            },
            .command("setting", "Change one Settings value by key, through the same path as the Settings window (persists, applies live unless noted). Returns the previous and new value.",
                     parameters: [
                         .string("key", "the setting", required: true, choices: settingsTable.map(\.key)),
                         .string("value", "the new value: a number, true/false, or one of the key's choices (GET /settings)", required: true),
                     ]) { args in
                let settings = try model().gameSettings
                let key = try args.requireString("key")
                guard let entry = settingsTable.first(where: { $0.key == key }) else {
                    throw DebugError(.notFound, "no setting '\(key)'", hint: "GET /settings lists the keys")
                }
                let previous = entry.get(settings)
                try entry.set(settings, try args.requireString("value"))
                var reply: [String: JSONValue] = ["key": .string(key), "previous": previous, "value": entry.get(settings)]
                if let note = entry.note { reply["note"] = .string(note) }
                return reply
            },
            .command("map", "Load a map (`map <name>`), discarding the current level's unsaved progress. Waits up to 20 s for it to load and returns the state.",
                     parameters: [.string("name", "the map, e.g. c1a0, c2a5, t0a0 (Opposing Force: of1a1, Blue Shift: ba_tram1)", required: true)],
                     destructive: true, timeout: .seconds(30)) { args in
                let app = try requireEngine()
                let name = try plainToken(try args.requireString("name"), "name", endpoint: "map")
                AppLog.app.log("[DebugServer] map \(name, privacy: .public)")
                app.gameSettings.command("map \(name)")
                let loaded = await waitFor(20) {
                    lambda_engine_loading() == 0 && lambda_debug_in_game() != 0 && mapName() == name
                }
                guard loaded else {
                    throw DebugError(.timeout, "'\(name)' did not finish loading within 20 s",
                                     hint: "the map may not exist in this game (the engine prints why to its console); GET /state shows the map now loaded")
                }
                return try stateReply()
            },
            .command("immersive", "Open or close the immersive space (the game). Opening starts the engine on first use. Returns the state once it settles (up to 15 s).",
                     parameters: [.boolean("open", "true = open (Show Immersive Space), false = close", required: true)],
                     timeout: .seconds(20)) { args in
                let app = try model()
                let open = try args.requireBool("open")
                if open {
                    guard app.immersiveSpaceState == .closed else { return try stateReply() }
                    guard !app.isPreparing, !app.library.isImporting else {
                        throw DebugError.failedPrecondition("the app is still preparing (weapon warm-up or an import)",
                                                            hint: "poll GET /state until preparing is false, then retry")
                    }
                    guard let openImmersive else { throw DebugError.unavailable("the main window isn't up", hint: "open the app's main window") }
                    app.immersiveSpaceState = .inTransition
                    if await !openImmersive() { app.immersiveSpaceState = .closed }
                    _ = await waitFor(15) { app.immersiveSpaceState == .open && app.gameSettings.isEngineReady }
                } else {
                    guard app.immersiveSpaceState == .open else { return try stateReply() }
                    guard let dismissImmersive else { throw DebugError.unavailable("the main window isn't up", hint: "open the app's main window") }
                    app.immersiveSpaceState = .inTransition
                    await dismissImmersive()
                    _ = await waitFor(5) { app.immersiveSpaceState == .closed }
                }
                return try stateReply()
            },
        ]
    }
}
