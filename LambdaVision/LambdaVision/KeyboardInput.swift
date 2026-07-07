//
//  KeyboardInput.swift
//  LambdaVision
//
//  Routes hardware-keyboard events (via GameController framework) into the
//  engine as console commands. visionOS doesn't surface raw SDL input, so
//  we sidestep xash's bindings layer and dispatch +/− commands directly.
//

import GameController

@MainActor
final class KeyboardInput {
    static let shared = KeyboardInput()
    private var observer: NSObjectProtocol?

    // Debug map cycling (`,` = restart, `.` = next map): early-chapter
    // list for quickly validating audio/controls across areas. Order
    // matches the campaign: tram ride → Anomalous Materials → Unforeseen
    // Consequences.
    private static let debugMaps = ["c0a0", "c0a0a", "c0a0b", "c0a0c",
                                    "c0a0d", "c0a0e",
                                    "c1a0", "c1a0a", "c1a0b", "c1a0c",
                                    "c1a0d", "c1a0e", "c1a1", "c1a1a"]
    private var debugMapIndex = 0
    private var netGraphMode = 0

    func start() {
        // Hook any keyboard that's already connected, plus future connects.
        if let kb = GCKeyboard.coalesced { attach(kb) }
        observer = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main) { note in
                if let kb = note.object as? GCKeyboard {
                    Task { @MainActor in KeyboardInput.shared.attach(kb) }
                }
            }
    }

    private func attach(_ kb: GCKeyboard) {
        guard let input = kb.keyboardInput else { return }
        input.keyChangedHandler = { _, _, code, pressed in
            // Snap turn (Z/X), 30° per press — an exact step added to the
            // engine's view yaw, not the frametime-dependent +left/right.
            // (Q/E stay on their HL meanings: lastinv / use.)
            if pressed, code == .keyZ { Renderer.requestSnapTurn(-1); return }
            if pressed, code == .keyX { Renderer.requestSnapTurn(1); return }
            // Debug: `,` restarts the map, `.` jumps to the next one.
            if pressed, code == .comma {
                _ = "restart".withCString { lambda_gl_worker_cmd($0) }
                return
            }
            if pressed, code == .period {
                Task { @MainActor in
                    let shared = KeyboardInput.shared
                    shared.debugMapIndex = (shared.debugMapIndex + 1) % KeyboardInput.debugMaps.count
                    let cmd = "map \(KeyboardInput.debugMaps[shared.debugMapIndex])"
                    _ = cmd.withCString { lambda_gl_worker_cmd($0) }
                }
                return
            }
            // Debug: G cycles net_graph (0 off → 1 full → 2 frame-time
            // graph → 3 compact) — the in-headset frame pacing readout.
            if pressed, code == .keyG {
                Task { @MainActor in
                    let shared = KeyboardInput.shared
                    shared.netGraphMode = (shared.netGraphMode + 1) % 4
                    let cmd = "net_graph \(shared.netGraphMode)"
                    _ = cmd.withCString { lambda_gl_worker_cmd($0) }
                }
                return
            }
            // One-shot debug keys fire on press only.
            if pressed, let oneshot = KeyboardInput.oneShot(for: code) {
                _ = oneshot.withCString { lambda_gl_worker_cmd($0) }
                return
            }
            guard let cmd = KeyboardInput.command(for: code) else { return }
            let full = (pressed ? "+" : "-") + cmd
            _ = full.withCString { lambda_gl_worker_cmd($0) }
        }
    }

    private static func oneShot(for code: GCKeyCode) -> String? {
        switch code {
        case .keyV: return "noclip"
        case .keyF: return "impulse 100" // flashlight
        case .keyK: return "impulse 101" // give all weapons (cheat)
        case .keyQ: return "lastinv"     // quick weapon switch
        // Weapon slots (HL uses 1-5; higher slots exist for mods).
        // hud_fastswitch is left to the user's config: without it the
        // slot opens the HUD picker, another press/attack confirms.
        case .one:   return "slot1"
        case .two:   return "slot2"
        case .three: return "slot3"
        case .four:  return "slot4"
        case .five:  return "slot5"
        case .six:   return "slot6"
        case .seven: return "slot7"
        case .eight: return "slot8"
        case .nine:  return "slot9"
        default:    return nil
        }
    }

    // Map keyboard scan code → xash console action (without the leading sign).
    private static func command(for code: GCKeyCode) -> String? {
        switch code {
        case .keyW, .upArrow:    return "forward"
        case .keyS, .downArrow:  return "back"
        case .keyA:              return "moveleft"
        case .keyD:              return "moveright"
        case .leftArrow:         return "left"   // yaw
        case .rightArrow:        return "right"
        case .spacebar:          return "jump"
        case .leftControl, .rightControl: return "duck"
        case .leftShift, .rightShift:     return "speed"
        case .keyR:              return "reload"
        case .keyE:              return "use"
        default:                 return nil
        }
    }
}
