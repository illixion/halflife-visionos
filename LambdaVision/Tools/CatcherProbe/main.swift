// Checks the input catcher's pure rule and rolling counter on the Mac,
// compiled together with the app's InputCatcherRule.swift and InputMode.swift.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

let base = InputCatcherInputs(enabled: true, immersiveOpen: true, engineReady: true, inGame: true,
                              loading: false, menuOpen: false, consoleOpen: false,
                              mode: .keyboardMouse, setting: .auto, mouseConnected: true,
                              mouseConnectedAt: 10, lastHandsAt: nil)
func wanted(_ change: (inout InputCatcherInputs) -> Void) -> Bool {
    var i = base
    change(&i)
    return InputCatcherRule.evaluate(i).wanted
}

check(wanted { _ in }, "keyboard+mouse in game: up")
check(!wanted { $0.enabled = false }, "setting off: down")
check(!wanted { $0.immersiveOpen = false }, "immersive closed: down")
check(!wanted { $0.inGame = false }, "not in game: down")
check(!wanted { $0.loading = true }, "loading: down")
check(!wanted { $0.menuOpen = true }, "menu: down")
check(!wanted { $0.consoleOpen = true }, "console: down")
check(!wanted { $0.mode = .gamepad }, "gamepad: down")
check(wanted { $0.mode = .hands }, "auto, hands, mouse connected, no pinch yet: up")
check(!wanted { $0.mode = .hands; $0.lastHandsAt = 12 }, "auto, pinched after the mouse connected: down")
check(wanted { $0.mode = .hands; $0.lastHandsAt = 5 }, "auto, pinched only before the mouse connected: up")
check(!wanted { $0.mode = .hands; $0.setting = .hands }, "forced hands: down")
check(!wanted { $0.mode = .hands; $0.mouseConnected = false }, "auto, hands, no mouse: down")

var r = RollingRate()
check(r.lastSecond(at: 0) == 0, "rate: empty")
// 10 events in each of the buckets 1.0, 1.1, 1.2, 1.3, 1.4 (mid-bucket times).
for b in 0..<5 { r.record(at: 1.05 + Double(b) * 0.1, count: 10) }
check(r.lastSecond(at: 1.55) == 50, "rate: 50 within the second")
check(r.lastSecond(at: 2.25) == 20, "rate: older buckets aged out")   // window 1.3…2.2
check(r.lastSecond(at: 2.6) == 0, "rate: all aged out")
r.record(at: 10)
check(r.lastSecond(at: 10.05) == 1, "rate: after a long gap")
check(r.total == 51, "rate: total kept")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("all checks passed")
