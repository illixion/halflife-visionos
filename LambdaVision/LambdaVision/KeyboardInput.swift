//
//  KeyboardInput.swift
//  LambdaVision
//
//  Forwards hardware-keyboard input (via GameController) into the engine as
//  real key + character events (Lambda_Bridge lambda_key_event/char_event),
//  so the stock Half-Life bind system, console, and menu text fields all work
//  and keys are reconfigurable in-game. Printable keys send a Key_Event with
//  the lowercase-ascii keynum plus, on press, the shifted character for
//  console/menu text (ignored in game). Default binds are set at engine init
//  (Lambda_Bridge). Z/X stay app-side as snap turn (not an HL concept).
//  Controllers are configured via visionOS System Settings.
//

import GameController
import QuartzCore

@MainActor
final class KeyboardInput {
    static let shared = KeyboardInput()
    private var observer: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    // Shift state, tracked for character shifting. Touched from the (possibly
    // off-main) GameController handler; a plain bool with benign tearing.
    nonisolated(unsafe) private static var shiftDown = false

    // Keyboard activity, read by the render thread to stand the hand
    // gestures down: hands resting on the keys read as pinches, fists and
    // pokes (a phantom +use, a crouch that drops WASD to a walk). Same
    // benign-tearing scalars as shiftDown.
    nonisolated(unsafe) private static var keysDown = Set<GCKeyCode>()
    nonisolated(unsafe) private static var lastKeyTime: TimeInterval = -.infinity
    /// How long after the last key event the keyboard still counts as in use.
    nonisolated static let idleSeconds: TimeInterval = 4

    /// A key is held, or one was pressed or released in the last few seconds.
    nonisolated static func inUse(now: TimeInterval) -> Bool {
        !keysDown.isEmpty || now - lastKeyTime < idleSeconds
    }

    /// Release every key the engine was told is down, and the mouse buttons:
    /// the input mode left the keyboard and mouse (InputHandoff). The keys
    /// stay in `keysDown` (they may still be physically held); the engine
    /// ignores the real release that follows, for a key it already let go.
    /// On the main queue, where GameController delivers key changes.
    nonisolated static func releaseHeld() {
        DispatchQueue.main.async {
            for code in keysDown {
                if let keynum = baseChar(for: code) ?? specialKeynum(for: code) {
                    lambda_key_event(Int32(keynum), 0)
                }
            }
            for keynum in Int32(241)...245 { lambda_key_event(keynum, 0) }   // K_MOUSE1…5
        }
    }

    func start() {
        if let kb = GCKeyboard.coalesced { attach(kb) }
        observer = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main) { note in
                if let kb = note.object as? GCKeyboard {
                    Task { @MainActor in KeyboardInput.shared.attach(kb) }
                }
            }
        // The last keyboard going away (and no mouse) hands the input mode
        // back to the hands.
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
                if GCKeyboard.coalesced == nil, !MouseInput.connected {
                    InputModeState.deviceGone(.keyboardMouse)
                }
            }
        MouseInput.shared.start()
    }

    private func attach(_ kb: GCKeyboard) {
        guard let input = kb.keyboardInput else { return }
        input.keyChangedHandler = { _, _, code, pressed in
            if pressed { KeyboardInput.keysDown.insert(code) } else { KeyboardInput.keysDown.remove(code) }
            KeyboardInput.lastKeyTime = CACurrentMediaTime()
            InputModeState.deviceUsed(.keyboardMouse, now: KeyboardInput.lastKeyTime)

            // Snap turn (Z/X): an exact yaw step, not an HL bind. Only in
            // game: in the console or the menu they are letters.
            let typing = lambda_console_active() != 0 || lambda_menu_active() != 0
            if !typing, code == .keyZ || code == .keyX {
                if pressed { Renderer.requestSnapTurn(code == .keyZ ? -1 : 1) }
                return
            }

            if code == .leftShift || code == .rightShift {
                KeyboardInput.shiftDown = pressed
            }

            if let base = KeyboardInput.baseChar(for: code) {
                lambda_key_event(Int32(base), pressed ? 1 : 0)
                if pressed {
                    let ch = KeyboardInput.shiftDown
                        ? (KeyboardInput.shiftedChar(for: code) ?? base) : base
                    lambda_char_event(Int32(ch))
                }
            } else if let keynum = KeyboardInput.specialKeynum(for: code) {
                lambda_key_event(Int32(keynum), pressed ? 1 : 0)
            }
        }
    }

    // Printable keys → unshifted ASCII. This doubles as the xash keynum
    // (keydefs.h: "normal keys should be passed as lowercased ascii").
    nonisolated private static func baseChar(for code: GCKeyCode) -> Int? {
        switch code {
        case .keyA: return 97; case .keyB: return 98; case .keyC: return 99
        case .keyD: return 100; case .keyE: return 101; case .keyF: return 102
        case .keyG: return 103; case .keyH: return 104; case .keyI: return 105
        case .keyJ: return 106; case .keyK: return 107; case .keyL: return 108
        case .keyM: return 109; case .keyN: return 110; case .keyO: return 111
        case .keyP: return 112; case .keyQ: return 113; case .keyR: return 114
        case .keyS: return 115; case .keyT: return 116; case .keyU: return 117
        case .keyV: return 118; case .keyW: return 119; case .keyX: return 120
        case .keyY: return 121; case .keyZ: return 122
        case .one: return 49; case .two: return 50; case .three: return 51
        case .four: return 52; case .five: return 53; case .six: return 54
        case .seven: return 55; case .eight: return 56; case .nine: return 57
        case .zero: return 48
        case .spacebar: return 32
        case .hyphen: return 45; case .equalSign: return 61
        case .openBracket: return 91; case .closeBracket: return 93
        case .backslash: return 92; case .semicolon: return 59
        case .quote: return 39; case .graveAccentAndTilde: return 96
        case .comma: return 44; case .period: return 46; case .slash: return 47
        default: return nil
        }
    }

    // Shifted (US-layout) character for text entry.
    nonisolated private static func shiftedChar(for code: GCKeyCode) -> Int? {
        // Letters: uppercase = lowercase − 32.
        if let base = baseChar(for: code), base >= 97, base <= 122 {
            return base - 32
        }
        switch code {
        case .one: return 33   // !
        case .two: return 64   // @
        case .three: return 35 // #
        case .four: return 36  // $
        case .five: return 37  // %
        case .six: return 94   // ^
        case .seven: return 38 // &
        case .eight: return 42 // *
        case .nine: return 40  // (
        case .zero: return 41  // )
        case .hyphen: return 95      // _
        case .equalSign: return 43   // +
        case .openBracket: return 123  // {
        case .closeBracket: return 125 // }
        case .backslash: return 124  // |
        case .semicolon: return 58   // :
        case .quote: return 34       // "
        case .graveAccentAndTilde: return 126 // ~
        case .comma: return 60       // <
        case .period: return 62      // >
        case .slash: return 63       // ?
        default: return nil
        }
    }

    // Non-printable keys → xash keynums (engine keydefs.h).
    nonisolated private static func specialKeynum(for code: GCKeyCode) -> Int? {
        switch code {
        case .tab: return 9
        case .returnOrEnter, .keypadEnter: return 13
        case .escape: return 27
        case .deleteOrBackspace: return 127
        case .upArrow: return 128
        case .downArrow: return 129
        case .leftArrow: return 130
        case .rightArrow: return 131
        case .leftAlt, .rightAlt: return 132
        case .leftControl, .rightControl: return 133
        case .leftShift, .rightShift: return 134
        case .F1: return 135; case .F2: return 136; case .F3: return 137
        case .F4: return 138; case .F5: return 139; case .F6: return 140
        case .F7: return 141; case .F8: return 142; case .F9: return 143
        case .F10: return 144; case .F11: return 145; case .F12: return 146
        case .insert: return 147; case .deleteForward: return 148
        case .pageDown: return 149; case .pageUp: return 150
        case .home: return 151; case .end: return 152
        case .capsLock: return 175
        default: return nil
        }
    }
}
