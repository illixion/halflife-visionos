//
//  ImportLog.swift
//  GameLibraryServer
//
//  Importer events as lines a person reads, for the page, the CLI and the
//  headset's modal; and the words for kinds and warnings.
//

import Foundation
import GameLibrary

public struct LogLine: Sendable, Equatable, Identifiable {
    public enum Level: String, Sendable { case info, warning, error, success }
    public let id: Int
    public var text: String
    public var level: Level
}

public enum ImportLog {
    /// A line for an event; nil for events shown otherwise (progress) or not at all.
    public static func describe(_ event: ImportEvent) -> (String, LogLine.Level)? {
        switch event {
        case .phase(let p):
            switch p {
            case .validating: return ("Checking files…", .info)
            case .extracting: return ("Unpacking…", .info)
            case .installing: return ("Installing…", .info)
            default: return nil
            }
        case .progress: return nil
        case .foundGamedir(let name, _): return ("Found \(name)", .info)
        case .refusedInUse(let name):
            return ("Skipped \(name): the running game uses it. Reopen LambdaVision and send it again before starting the game.", .warning)
        case .installed(let name, let mode, let files):
            return ("Installed \(name) (\(files) files, \(mode == .merge ? "merged" : "replaced"))", .success)
        case .normalized(let note):
            if case .wroteVFSConfig(let g) = note { return ("Turned on the HD pack for \(g)", .info) }
            return nil
        case .classified(let name, let kind): return ("\(name): \(kindLabel(kind))", .info)
        case .warning(let w): return (describe(w), .warning)
        case .finished(let s):
            return (s.installed.isEmpty ? "Nothing was installed." : "Done.", s.installed.isEmpty ? .warning : .success)
        }
    }

    public static func describe(_ error: Error) -> String {
        guard let error = error as? ImportError else { return "Import failed." }
        switch error {
        case .unsafePath, .symlink: return "This archive contains unsafe paths and was not imported."
        case .unreadableArchive: return "This isn't a zip archive LambdaVision can read."
        case .noGamedirs: return "No game folders found. A game folder holds a liblist.gam (like valve/ or gearbox/)."
        case .insufficientSpace(let needed, let available):
            return "Not enough space: needs \(bytes(needed)), \(bytes(available)) free."
        case .gameInUse(let dirs):
            return "\(dirs.joined(separator: ", ")) is in use by the running game. Reopen LambdaVision, then send it before starting the game."
        case .io: return "Couldn't write the game files."
        }
    }

    public static func describe(_ w: ImportWarning) -> String {
        switch w {
        case .ignoredEntries(let n): return "Skipped \(n) macOS metadata files."
        case .orphanOverlay(let g): return "\(g) is an add-on for a game that isn't installed yet."
        case .missingFallbackDir(let g, let fb): return "\(g) needs \(fb), which isn't installed."
        case .postAnniversaryValve: return "This Half-Life is the 25th Anniversary build. Use the steam_legacy branch for the best results."
        case .customGameCode(let g):
            return "\(g) ships its own game code, which can't run here. Its maps run on Half-Life's code, so some of its own features will be missing."
        }
    }

    public static func describe(_ w: GameWarning) -> String {
        switch w {
        case .missingFallbackDir(let fb): return "Needs \(fb), which isn't installed."
        case .postAnniversaryValve: return "25th Anniversary build: the steam_legacy branch works best."
        }
    }

    public static func code(_ w: GameWarning) -> String {
        switch w {
        case .missingFallbackDir: return "missingFallbackDir"
        case .postAnniversaryValve: return "postAnniversaryValve"
        }
    }

    public static func kindLabel(_ kind: GameKind) -> String {
        switch kind {
        case .base: return "Ready"
        case .contentOnly: return "Content mod"
        case .compiledIn: return "Compiled-in"
        case .custom: return "Experimental"
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
