//
//  main.swift
//  library-server
//
//  The Wi-Fi management server on the Mac, for trying the page and the API
//  without a headset:
//
//      swift run library-server <GameData dir> [--port N] [--running <gamedir>]
//
//  It prints the PIN and URLs, then serves until interrupted. `--running`
//  pretends the engine runs that game, to try the in-use guards.
//

import Foundation
import GameLibrary
import GameLibraryServer

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let port = option("--port").flatMap(UInt16.init) ?? 8642
let runningName = option("--running")
guard let rootArg = args.first else {
    FileHandle.standardError.write(Data("usage: library-server <GameData dir> [--port N] [--running <gamedir>]\n".utf8))
    exit(2)
}

let root = URL(fileURLWithPath: rootArg).standardizedFileURL
let work = root.deletingLastPathComponent().appendingPathComponent(".library-server")
let library = GameLibrary(root: root, manifestURL: work.appendingPathComponent("library-manifest.json"),
                          compiledGames: [CompiledGame(gamedir: "valve", dll: "hl", title: "Half-Life"),
                                          CompiledGame(gamedir: "gearbox", dll: "opfor", title: "Opposing Force"),
                                          CompiledGame(gamedir: "bshift", dll: "bshift", title: "Blue Shift")])

final class Active: @unchecked Sendable {
    var gamedir: String?
    let lock = NSLock()
}
let active = Active()
let running = runningName.flatMap { name in library.refresh().scan.game(name) }

var config = LibraryServer.Configuration(library: library, uploadRoot: work.appendingPathComponent("upload"),
                                         importStagingRoot: work.appendingPathComponent("import"),
                                         hashCacheURL: work.appendingPathComponent("hashes.json"))
config.preferredPort = port
let server = LibraryServer(config, host: .init(
    runningGame: { running },
    activeGamedir: { active.lock.withLock { active.gamedir } },
    setActive: { dir in
        active.lock.withLock { active.gamedir = dir }
        return running.map { $0.gamedir.lowercased() == dir.lowercased() ? nil : "Reopen LambdaVision to switch." } ?? nil
    },
    onEvent: { event in
        switch event {
        case .pinChanged(let pin): print("PIN changed: \(pin)")
        case .sessions(let n): print("sessions: \(n)")
        case .log(let line): print("[\(line.level.rawValue)] \(line.text)")
        case .importing(let on): print(on ? "import started" : "import finished")
        case .failed(let why): print("listener failed: \(why)"); exit(1)
        default: break
        }
    }))

Task {
    do {
        let bound = try await server.start()
        print("PIN: \(server.pin)")
        if let name = NetworkInfo.localHostName() { print("URL: http://\(name):\(bound)") }
        for ip in NetworkInfo.ipv4Addresses() { print("URL: http://\(ip):\(bound)") }
        print("URL: http://127.0.0.1:\(bound)")
    } catch {
        print("failed to start: \(error)")
        exit(1)
    }
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let stopSource = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { server.stop(); print("stopped"); exit(0) }
    s.resume()
    return s
}
_ = stopSource
dispatchMain()
