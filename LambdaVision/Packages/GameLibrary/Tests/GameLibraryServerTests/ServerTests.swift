//
//  ServerTests.swift
//  GameLibraryServerTests
//
//  The Wi-Fi server end to end over loopback: pairing and its rate limits,
//  path safety, uploads streamed to disk, manifests for diffing and
//  resuming, imports through the API, and the running-game guards.
//

import CryptoKit
import Foundation
import Network
import Testing
import ZIPFoundation
@testable import GameLibrary
@testable import GameLibraryServer

// MARK: - Fixtures

final class Box {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gls-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var gameData: URL { url.appendingPathComponent("GameData") }
    func write(_ files: [String: String], under rel: String = "GameData") throws {
        for (p, text) in files {
            let f = url.appendingPathComponent(rel).appendingPathComponent(p)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: f)
        }
    }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(rel).path) }
    func files(under rel: String) -> [String] {
        (FileManager.default.enumerator(atPath: url.appendingPathComponent(rel).path)?.allObjects as? [String]) ?? []
    }
}

let valveFiles = [
    "valve/liblist.gam": "game \"Half-Life\"\ngamedll \"dlls\\\\hl.dll\"\n",
    "valve/dlls/hl.dll": "HL",
    "valve/maps/c0a0.bsp": "map",
    "valve_hd/models/hgrunt03.mdl": "hd",
]

final class Running: @unchecked Sendable {
    var game: GameEntry?
}

struct Harness {
    let box: Box
    let server: LibraryServer
    let base: URL
    let running: Running

    static func make(policy: Pairing.Policy = Pairing.Policy()) async throws -> Harness {
        let box = try Box()
        try box.write(valveFiles)
        let library = GameLibrary(root: box.gameData, manifestURL: nil, compiledGames: [])
        var config = LibraryServer.Configuration(library: library, uploadRoot: box.url.appendingPathComponent("upload"),
                                                 importStagingRoot: box.url.appendingPathComponent("import"),
                                                 hashCacheURL: box.url.appendingPathComponent("hashes.json"))
        config.preferredPort = 0
        config.advertise = false
        config.loopbackOnly = true
        config.pairingPolicy = policy
        let running = Running()
        let server = LibraryServer(config, host: .init(runningGame: { running.game }))
        let port = try await server.start()
        return Harness(box: box, server: server, base: URL(string: "http://127.0.0.1:\(port)")!, running: running)
    }

    func pair() async throws -> String {
        let (data, status, _) = try await request("POST", "/api/pair", json: ["pin": server.pin])
        #expect(status == 200)
        return try #require(json(data)["token"] as? String)
    }

    @discardableResult
    func request(_ method: String, _ path: String, token: String? = nil, json body: [String: Any]? = nil,
                 data: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, Int, HTTPURLResponse) {
        var r = URLRequest(url: URL(string: base.absoluteString + path)!)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if let data { r.httpBody = data }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await Self.session.data(for: r)
        let http = resp as! HTTPURLResponse
        return (d, http.statusCode, http)
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    func upload(_ path: String, _ data: Data, token: String, mtime: Double? = nil, sha: String? = nil) async throws -> Int {
        var q = "path=" + path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        if let mtime { q += "&mtime=\(mtime)" }
        if let sha { q += "&sha256=\(sha)" }
        return try await request("PUT", "/api/upload?" + q, token: token, data: data).1
    }

    func manifest(_ gamedir: String, token: String) async throws -> [String: Any] {
        json(try await request("GET", "/api/manifest?gamedir=\(gamedir)", token: token).0)
    }

    func library(_ token: String) async throws -> [[String: Any]] {
        (json(try await request("GET", "/api/library", token: token).0)["games"] as? [[String: Any]]) ?? []
    }

    /// Waits for the server's import to finish.
    func waitForImport() async throws {
        for _ in 0..<200 {
            if !server.isImporting { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("import didn't finish")
    }
}

func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

// MARK: - Pairing

@Suite struct PairingTests {
    @Test func pinIsSixDigitsAndPairsOnce() {
        let p = Pairing()
        #expect(p.pin.count == 6 && p.pin.allSatisfy(\.isNumber))
        guard case .paired(let token) = p.attempt(p.pin) else { Issue.record("didn't pair"); return }
        #expect(p.validate(token))
        #expect(!p.validate("nope"))
        #expect(!p.validate(nil))
        p.revokeAll()
        #expect(!p.validate(token))
    }

    @Test func wrongAttemptsCoolDownThenRegenerate() {
        let clock = Clock()
        let p = Pairing(now: { clock.now })
        let pin = p.pin
        let wrong = pin == "000000" ? "111111" : "000000"
        let changed = Running()
        nonisolated(unsafe) var newPIN: String?
        p.onPINChange = { newPIN = $0 }
        _ = changed

        #expect(p.attempt(wrong) == .wrong(regenerated: false))
        // Inside the cooldown even the right PIN isn't checked.
        #expect(p.attempt(pin) == .tooSoon(retryAfter: 1))
        for i in 2...5 {
            clock.now += 1.1
            #expect(p.attempt(wrong) == .wrong(regenerated: i == 5))
        }
        #expect(p.pin != pin)
        #expect(newPIN == p.pin)
        // Locked out for the longer pause, then the old PIN is dead.
        clock.now += 5
        if case .tooSoon(let wait) = p.attempt(p.pin) { #expect(wait >= 20) } else { Issue.record("not locked out") }
        clock.now += 30
        #expect(p.attempt(pin) == .wrong(regenerated: false))
        clock.now += 1.1
        guard case .paired = p.attempt(p.pin) else { Issue.record("new PIN didn't pair"); return }
    }

    @Test func acceptsSpacesInThePIN() {
        let p = Pairing()
        let spaced = String(p.pin.prefix(3)) + " " + String(p.pin.suffix(3))
        guard case .paired = p.attempt(spaced) else { Issue.record("spaced PIN refused"); return }
    }

    @Test func overHTTP() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        // Unpaired: the API refuses, the page itself loads.
        #expect(try await h.request("GET", "/api/library").1 == 401)
        let (page, status, resp) = try await h.request("GET", "/")
        #expect(status == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("Enter the PIN"))
        #expect(resp.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("default-src 'self'") == true)
        let wasm = try await h.request("GET", "/vendor/libarchive/libarchive.wasm")
        #expect(wasm.1 == 200 && wasm.2.value(forHTTPHeaderField: "Content-Type") == "application/wasm")

        let (bad, badStatus, _) = try await h.request("POST", "/api/pair", json: ["pin": h.server.pin == "123456" ? "654321" : "123456"])
        #expect(badStatus == 401)
        #expect(json(bad)["regenerated"] as? Bool == false)
        #expect(try await h.request("POST", "/api/pair", json: ["pin": h.server.pin]).1 == 429)
        try await Task.sleep(for: .milliseconds(1100))
        let (_, ok, okResp) = try await h.request("POST", "/api/pair", json: ["pin": h.server.pin])
        #expect(ok == 200)
        let cookie = try #require(okResp.value(forHTTPHeaderField: "Set-Cookie"))
        #expect(cookie.contains("HttpOnly") && cookie.contains("SameSite=Strict"))
        // The cookie works like the bearer token.
        let token = String(cookie.split(separator: ";")[0].split(separator: "=")[1])
        #expect(try await h.request("GET", "/api/status", headers: ["Cookie": "lv_session=\(token)"]).1 == 200)
        // Another site's page can't post through the visitor's browser.
        #expect(try await h.request("POST", "/api/delete", token: token, json: ["gamedir": "valve"],
                                    headers: ["Origin": "http://evil.example"]).1 == 403)
        // Sessions die with the server.
        h.server.stop()
        #expect(!h.server.pairing.validate(token))
    }
}

// MARK: - Paths

@Suite struct PathSafetyTests {
    @Test(arguments: ["../evil", "valve/../../evil", "/etc/passwd", "C:\\evil", "..\\evil", "valve/../x", "~/x"])
    func rejectsEscapes(_ path: String) {
        #expect(throws: (any Error).self) { try UploadStore.split(path) }
    }

    @Test func needsAGamedir() {
        #expect(throws: HTTPError.self) { try UploadStore.split("liblist.gam") }
        #expect(throws: HTTPError.self) { try UploadStore.split(".hidden/x") }
    }

    @Test func skipsJunkAndNormalizes() throws {
        #expect(try UploadStore.split("mod/__MACOSX/x") == nil)
        #expect(try UploadStore.split("mod/._x") == nil)
        let s = try #require(try UploadStore.split("mod\\maps\\./a.bsp"))
        #expect(s.gamedir == "mod" && s.relative == "maps/a.bsp")
    }

    @Test func overHTTP() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        #expect(try await h.upload("../evil.txt", Data("x".utf8), token: token) == 422)
        #expect(try await h.upload("mod/../../evil.txt", Data("x".utf8), token: token) == 422)
        #expect(try await h.upload("/tmp/evil.txt", Data("x".utf8), token: token) == 422)
        #expect(!h.box.exists("evil.txt"))
        #expect(try await h.request("GET", "/api/manifest?gamedir=..", token: token).1 == 400)
        #expect(try await h.request("POST", "/api/delete", token: token, json: ["gamedir": "../GameData"]).1 == 400)
        #expect(try await h.request("GET", "/../Package.swift").1 == 404)
    }

    @Test func symlinkPlantedInStagingFailsTheImport() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        #expect(try await h.upload("mod/liblist.gam", Data("game \"m\"".utf8), token: token) == 200)
        try FileManager.default.createSymbolicLink(atPath: h.server.store.tree.path + "/mod/link",
                                                   withDestinationPath: "/etc")
        #expect(try await h.request("POST", "/api/commit", token: token).1 == 202)
        try await h.waitForImport()
        #expect(!h.box.exists("GameData/mod"))
        #expect(h.server.recentLog.contains { $0.text.contains("unsafe paths") })
    }
}

// MARK: - Uploads

@Suite struct UploadTests {
    @Test func streamsToDiskAndKeepsMtime() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        var payload = Data(count: 24 << 20)
        payload.withUnsafeMutableBytes { p in for i in stride(from: 0, to: p.count, by: 4096) { p[i] = UInt8(i / 4096 & 0xff) } }
        #expect(try await h.upload("mod/maps/big.bsp", payload, token: token, mtime: 1_700_000_000, sha: sha256(payload)) == 200)
        let staged = h.server.store.tree.appendingPathComponent("mod/maps/big.bsp")
        #expect(try Data(contentsOf: staged) == payload)
        let mtime = try FileManager.default.attributesOfItem(atPath: staged.path)[.modificationDate] as? Date
        #expect(mtime?.timeIntervalSince1970 == 1_700_000_000)
        #expect(h.box.files(under: "upload/parts").isEmpty)
        #expect(h.server.uploadProgress.completedFiles == 1)
    }

    @Test func checksumMismatchSavesNothing() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        #expect(try await h.upload("mod/a.txt", Data("abc".utf8), token: token, sha: String(repeating: "0", count: 64)) == 422)
        #expect(!FileManager.default.fileExists(atPath: h.server.store.tree.path + "/mod/a.txt"))
    }

    /// Half a body sent and the connection held: the bytes are already on
    /// disk (not buffered in memory); dropping the connection then leaves
    /// neither a staged file nor a part file behind.
    @Test func bodyReachesDiskBeforeItEndsAndADropLeavesNothing() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        let total = 8 << 20
        let client = RawClient(port: UInt16(h.base.port!))
        try await client.connect()
        try await client.send(Data("PUT /api/upload?path=mod/half.bin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(total)\r\n\r\n".utf8))
        try await client.send(Data(count: total / 2))
        var onDisk = 0
        for _ in 0..<100 {
            onDisk = h.box.files(under: "upload/parts").reduce(0) { n, f in
                n + ((try? FileManager.default.attributesOfItem(atPath: h.box.url.appendingPathComponent("upload/parts/" + f).path)[.size] as? Int) ?? 0)
            }
            if onDisk >= total / 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(onDisk >= total / 2)
        #expect(h.server.uploadProgress.receivedBytes >= Int64(total / 2))
        client.cancel()
        for _ in 0..<100 where !h.box.files(under: "upload/parts").isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(h.box.files(under: "upload/parts").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.server.store.tree.path + "/mod/half.bin"))
    }

    @Test func refusesTheRunningGame() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        h.running.game = GameLibrary(root: h.box.gameData, manifestURL: nil, compiledGames: []).refresh().scan.game("valve")
        #expect(try await h.upload("valve/maps/new.bsp", Data("x".utf8), token: token) == 409)
        #expect(try await h.upload("VALVE_hd/models/x.mdl", Data("x".utf8), token: token) == 409)
        #expect(try await h.request("POST", "/api/delete", token: token, json: ["gamedir": "valve"]).1 == 409)
        #expect(h.box.exists("GameData/valve/maps/c0a0.bsp"))
        let lib = try await h.library(token)
        #expect(lib.first?["inUse"] as? Bool == true)
        // Other gamedirs are fine.
        #expect(try await h.upload("mod/liblist.gam", Data("game \"m\"".utf8), token: token) == 200)
    }
}

// MARK: - Manifests

@Suite struct ManifestTests {
    /// The client's rule (app.js `same`, push-assets.sh): equal size and
    /// mtime, or equal size and hash.
    static func toSend(_ local: [String: (Data, Double)], manifest: [String: Any]) -> Set<String> {
        var known: [String: [String: Any]] = [:]
        for key in ["files", "staged"] {
            for f in manifest[key] as? [[String: Any]] ?? [] {
                let p = (f["path"] as! String).lowercased()
                if known[p] == nil || key == "staged" { known[p] = f }
            }
        }
        return Set(local.filter { path, value in
            guard let f = known[path.lowercased()], (f["size"] as? Int) == value.0.count else { return true }
            if abs((f["mtime"] as? Double ?? 0) - value.1) < 2 { return false }
            return (f["sha256"] as? String) != sha256(value.0)
        }.keys)
    }

    @Test func diffAndResume() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        // Installed valve, seen case-insensitively; one file changed, one new.
        let local: [String: (Data, Double)] = [
            "liblist.gam": (Data(valveFiles["valve/liblist.gam"]!.utf8), 1),        // same bytes, other mtime → hash says same
            "MAPS/c0a0.bsp": (Data("map".utf8), 1),                                    // case differs, same bytes
            "dlls/hl.dll": (Data("HX".utf8), 1),                                       // same size, different bytes
            "maps/c1a0.bsp": (Data("new map".utf8), 1_700_000_000),                    // new
            "maps/c1a1.bsp": (Data("another".utf8), 1_700_000_000),                    // new
        ]
        var m = try await h.manifest("valve", token: token)
        #expect(m["installed"] as? Bool == true)
        #expect((m["files"] as? [[String: Any]])?.count == 3)
        #expect(Self.toSend(local, manifest: m) == ["dlls/hl.dll", "maps/c1a0.bsp", "maps/c1a1.bsp"])

        // Send one, then "drop": the manifest's staged list resumes the rest.
        #expect(try await h.upload("valve/maps/c1a0.bsp", local["maps/c1a0.bsp"]!.0, token: token, mtime: 1_700_000_000) == 200)
        m = try await h.manifest("valve", token: token)
        #expect(Self.toSend(local, manifest: m) == ["dlls/hl.dll", "maps/c1a1.bsp"])

        // TSV for the shell script.
        let (tsv, _, _) = try await h.request("GET", "/api/manifest?gamedir=valve&format=tsv", token: token)
        let lines = String(decoding: tsv, as: UTF8.self).split(separator: "\n")
        #expect(lines.contains { $0.hasPrefix("s\t7\t1700000000\t") && $0.hasSuffix("\tmaps/c1a0.bsp") })
        #expect(lines.filter { $0.hasPrefix("i\t") }.count == 3)
    }

    @Test func hashesAreCachedAcrossServers() async throws {
        let h = try await Harness.make()
        let token = try await h.pair()
        _ = try await h.manifest("valve", token: token)
        h.server.stop()
        try await Task.sleep(for: .milliseconds(700))   // stop saves the cache
        let data = try Data(contentsOf: h.box.url.appendingPathComponent("hashes.json"))
        let cache = try JSONDecoder().decode([String: FileHashCache.Record].self, from: data)
        #expect(cache.keys.contains { $0.hasSuffix("valve/maps/c0a0.bsp") })
    }
}

// MARK: - Importing

@Suite struct ImportAPITests {
    @Test func commitInstallsStagedFiles() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        #expect(try await h.request("POST", "/api/commit", token: token).1 == 409)   // nothing staged
        #expect(try await h.upload("mymod/liblist.gam", Data("game \"My Mod\"\n".utf8), token: token) == 200)
        #expect(try await h.upload("mymod/maps/m1.bsp", Data("bsp".utf8), token: token) == 200)
        let (text, status, _) = try await h.request("POST", "/api/commit?stream=text", token: token)
        #expect(status == 200)
        let log = String(decoding: text, as: UTF8.self)
        #expect(log.contains("Installed mymod"))
        #expect(log.contains("mymod: Content mod"))
        #expect(h.box.exists("GameData/mymod/maps/m1.bsp"))
        #expect(h.server.store.isEmpty)
        let lib = try await h.library(token)
        #expect(lib.contains { $0["gamedir"] as? String == "mymod" && $0["kind"] as? String == "contentOnly" })
    }

    @Test func mergeKeepsUnsentFiles() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        #expect(try await h.upload("valve/maps/c1a0.bsp", Data("new".utf8), token: token) == 200)
        #expect(try await h.request("POST", "/api/commit?stream=text", token: token).1 == 200)
        #expect(h.box.exists("GameData/valve/maps/c0a0.bsp"))
        #expect(h.box.exists("GameData/valve/maps/c1a0.bsp"))
    }

    @Test func zipUploadImports() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        let zipURL = h.box.url.appendingPathComponent("Cool Mod.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (p, text) in ["liblist.gam": "game \"Cool\"\n", "maps/cool.bsp": "bsp"] {
            let d = Data(text.utf8)
            try archive.addEntry(with: p, type: .file, uncompressedSize: Int64(d.count)) { pos, size in
                d.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        let zip = try Data(contentsOf: zipURL)
        let (_, status, _) = try await h.request("PUT", "/api/upload-zip?name=Cool%20Mod.zip", token: token, data: zip)
        #expect(status == 202)
        try await Task.sleep(for: .milliseconds(100))
        try await h.waitForImport()
        // A zip with the gamedir at its top level is named after the archive.
        #expect(h.box.exists("GameData/Cool Mod/maps/cool.bsp"))
        #expect(h.box.files(under: "upload/zips").isEmpty)
    }

    @Test func deleteAndSetActive() async throws {
        let h = try await Harness.make()
        defer { h.server.stop() }
        let token = try await h.pair()
        try h.box.write(["other/liblist.gam": "game \"Other\"\n", "other_hd/models/a.mdl": "x"])
        #expect(try await h.request("POST", "/api/active", token: token, json: ["gamedir": "nope"]).1 == 404)
        #expect(try await h.request("POST", "/api/active", token: token, json: ["gamedir": "other"]).1 == 200)
        let (_, status, _) = try await h.request("POST", "/api/delete", token: token, json: ["gamedir": "OTHER"])
        #expect(status == 200)
        #expect(!h.box.exists("GameData/other"))
        #expect(!h.box.exists("GameData/other_hd"))
        #expect(h.box.exists("GameData/valve"))
    }
}

// MARK: - Raw TCP

/// A bare TCP client, to send a request body in pieces.
final class RawClient: @unchecked Sendable {
    let connection: NWConnection
    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }
    func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { c.resume() }
                case .failed(let e): if once.claim() { c.resume(throwing: e) }
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }
    func cancel() { connection.forceCancel() }
}
