/*
 LambdaVision — structured logging.

 This app printed everything. `print()` goes to stdout, which the unified
 logging system never sees — so nothing it emitted could be read on device
 without a cable. These are DebugTrace `DebugLogger` categories instead: each
 line lands in DebugTrace's in-memory ring (the in-app console and debug traces
 read it) and in the unified log, visible in Xcode and Console.app.

 Call them like `os.Logger`, marking each interpolation's privacy. Values are
 os_log's defaults — numbers and bools public, anything else private — so
 annotate technical strings (engine status, formats, model and bone names,
 states) `.public`, and leave container paths and errors private. Keep
 per-frame lines at `debug`, which is never built when nothing captures it.
 */

import DebugTrace
import Foundation

/// Nonisolated so any thread or actor can log: `DebugLogger` is `Sendable`.
nonisolated enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.LambdaVision"

    static let app = DebugLogger(subsystem: subsystem, category: "App")
    static let render = DebugLogger(subsystem: subsystem, category: "Render")
    static let input = DebugLogger(subsystem: subsystem, category: "Input")
    static let world = DebugLogger(subsystem: subsystem, category: "World")
    static let audio = DebugLogger(subsystem: subsystem, category: "Audio")
    static let perf = DebugLogger(subsystem: subsystem, category: "Perf")

    /// Tells DebugTrace which subsystem is the app's own, for traces and the
    /// in-app console. Called once at launch.
    static func configureDebugTrace() {
        DebugTrace.configure(.init(subsystems: [subsystem]))
    }
}
