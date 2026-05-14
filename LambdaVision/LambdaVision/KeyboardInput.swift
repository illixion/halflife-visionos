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
            guard let cmd = KeyboardInput.command(for: code) else { return }
            let full = (pressed ? "+" : "-") + cmd
            _ = full.withCString { lambda_gl_worker_cmd($0) }
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
        case .keyE:              return "use"
        default:                 return nil
        }
    }
}
