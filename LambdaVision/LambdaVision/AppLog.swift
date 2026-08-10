/*
 LambdaVision — structured logging.

 This app printed everything. `print()` goes to stdout, which the unified
 logging system never sees — so nothing it emitted could be read on device
 without a cable, and the in-app console would have shown an empty list forever.
 These are `os.Logger` categories instead: visible in Xcode and Console.app as
 before, and now also in the Console window.

 `line` and `detail` take an already-interpolated `String` rather than being
 `Logger` passthroughs, because `OSLogMessage` is a compiler-special type that
 cannot travel through a wrapper function. The cost is losing os_log's lazy
 formatting; the benefit is that the ~35 former `print` call sites needed no
 rewriting of their interpolation. Both mark the payload `.public` — without it
 os_log redacts interpolated values and every line reads `<private>`.
 */

import Foundation
import RAVEConsole
import os

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.LambdaVision"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let render = Logger(subsystem: subsystem, category: "Render")
    static let input = Logger(subsystem: subsystem, category: "Input")
    static let world = Logger(subsystem: subsystem, category: "World")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let perf = Logger(subsystem: subsystem, category: "Perf")
}

extension Logger {
    /// A pre-formatted line at default level, unredacted in OSLogStore.
    /// Only for messages with no sensitive content.
    func line(_ message: String) {
        self.log("\(message, privacy: .public)")
    }

    /// A verbose line that should reach the in-app console when one is open and
    /// cost nothing when it is not.
    ///
    /// The unified log keeps `.debug` in a memory ring buffer only — OSLogStore
    /// never returns it — so a plain `.debug` call is invisible in the console
    /// however the level filter is set. Promoting to `.info` while a viewer is
    /// registered is the way around that.
    func detail(_ message: String) {
        self.log(level: RAVELogStore.effectiveDebugLevel, "\(message, privacy: .public)")
    }
}
