//
//  LibraryServer.swift
//  GameLibraryServer
//
//  "Manage over Wi-Fi": a small HTTP server a browser (or
//  `scripts/push-assets.sh --wifi`) on the same network uses to list,
//  choose, delete and add games. It lives exactly as long as the headset's
//  modal: `start()` when it opens, `stop()` when it closes, which ends every
//  session and cuts off any upload in flight.
//
//  - Listener + Bonjour (`_http._tcp`) on a fixed preferred port, falling
//    back to the next few and then any free port. The pattern is RAVESDK's
//    RAVESetupReceiver (its QR pairing is not used: only the wearer can see
//    the headset's display, so a PIN they read out is the whole secret).
//  - Pairing: see Pairing.swift. The page swaps the PIN for an HttpOnly,
//    SameSite=Strict cookie; scripts get the same token as a bearer token.
//  - Uploads stream to disk (UploadStore); "commit" runs the importer on
//    the staging tree, a zip upload runs it on the zip. Both go through
//    GameImporter, so paths, symlinks, free space and the running game are
//    checked exactly as for AirDrop and Files imports.
//  - The running game's gamedirs (its content chain and overlays) are
//    refused for upload, delete and import alike.
//
//  Generic enough to be a LAN file-manager server for another app, but it
//  stays here until a second app wants one (the portfolio's sharing rule).
//

import Foundation
import GameLibrary
import Network

public final class LibraryServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var library: GameLibrary
        /// Staging tree, part files and uploaded zips. Same volume as GameData.
        public var uploadRoot: URL
        /// The importer's work dirs. Same volume as GameData.
        public var importStagingRoot: URL
        /// Where manifest hashes persist between server lifetimes.
        public var hashCacheURL: URL?
        public var preferredPort: UInt16 = 8642
        /// Ports after the preferred one tried before taking any free port.
        public var fallbackPorts: UInt16 = 8
        public var advertise = true
        public var serviceName = "LambdaVision"
        public var pairingPolicy = Pairing.Policy()
        /// The page's files; the bundled page when nil.
        public var webRoot: URL?
        /// Accept connections only over loopback (tests).
        public var loopbackOnly = false

        public init(library: GameLibrary, uploadRoot: URL, importStagingRoot: URL, hashCacheURL: URL? = nil) {
            self.library = library
            self.uploadRoot = uploadRoot
            self.importStagingRoot = importStagingRoot
            self.hashCacheURL = hashCacheURL
        }
    }

    /// The app's side: what's running, what's chosen, and what to tell it.
    public struct Host: Sendable {
        /// The game the engine runs, if it started.
        public var runningGame: @Sendable () -> GameEntry?
        /// The gamedir that launches next.
        public var activeGamedir: @Sendable () async -> String?
        /// Makes a game the one that launches; returns a note for the page
        /// ("Reopen LambdaVision to switch").
        public var setActive: @Sendable (String) async -> String?
        /// Whether an import may start now (the app's own import isn't running).
        public var mayImport: @Sendable () async -> Bool
        public var onEvent: @Sendable (Event) -> Void

        public init(runningGame: @escaping @Sendable () -> GameEntry? = { nil },
                    activeGamedir: @escaping @Sendable () async -> String? = { nil },
                    setActive: @escaping @Sendable (String) async -> String? = { _ in nil },
                    mayImport: @escaping @Sendable () async -> Bool = { true },
                    onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
            self.runningGame = runningGame; self.activeGamedir = activeGamedir
            self.setActive = setActive; self.mayImport = mayImport; self.onEvent = onEvent
        }
    }

    public struct UploadProgress: Sendable, Equatable {
        /// What the client said it is about to send (0 when it didn't).
        public var plannedFiles = 0
        public var plannedBytes: Int64 = 0
        public var completedFiles = 0
        /// Bytes received, including files still arriving.
        public var receivedBytes: Int64 = 0
        public var activeUploads = 0
        public var failedFiles = 0
    }

    public enum Event: Sendable {
        case pinChanged(String)
        case sessions(Int)
        case upload(UploadProgress)
        case importing(Bool)
        /// Fraction of the running import, when known.
        case importProgress(Double?)
        case log(LogLine)
        /// An import or delete changed GameData.
        case libraryChanged
        /// The listener stopped on its own (network gone); the string is why.
        case failed(String)
    }

    public static let serviceType = "_http._tcp"
    static let cookieName = "lv_session"

    public let configuration: Configuration
    public let host: Host
    public let pairing: Pairing
    public private(set) var port: UInt16?

    let store: UploadStore
    private let importer: GameImporter
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "GameLibraryServer.listener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var streams: [UUID: (stream: HTTPStream, token: String, text: Bool)] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var importing = false
    private var log: [LogLine] = []
    private var nextLogID = 0
    private var upload = UploadProgress()
    private var lastUploadEvent = Date.distantPast
    private var lastSessionCount = 0
    private var stopped = false

    public init(_ configuration: Configuration, host: Host = Host()) {
        self.configuration = configuration
        self.host = host
        pairing = Pairing(policy: configuration.pairingPolicy)
        store = UploadStore(root: configuration.uploadRoot, hashCacheURL: configuration.hashCacheURL)
        importer = GameImporter(library: configuration.library, stagingRoot: configuration.importStagingRoot)
        pairing.onPINChange = { [weak self] pin in self?.host.onEvent(.pinChanged(pin)) }
    }

    public var pin: String { pairing.pin }
    public var isImporting: Bool { lock.withLock { importing } }
    public var uploadProgress: UploadProgress { lock.withLock { upload } }
    public var recentLog: [LogLine] { lock.withLock { log } }

    /// Starts listening; returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        if let port { return port }
        var candidates: [UInt16] = []
        for i in 0...configuration.fallbackPorts { candidates.append(configuration.preferredPort &+ i) }
        candidates.append(0)
        var lastError: Error?
        for candidate in candidates {
            do {
                let bound = try await listen(on: candidate)
                port = bound
                startHeartbeat()
                return bound
            } catch NWError.posix(.EADDRINUSE) {
                continue
            } catch {
                lastError = error
                if candidate == 0 { break }
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    /// Stops listening, drops every connection and session, discards
    /// unfinished uploads. A running import finishes on its own.
    public func stop() {
        let (open, l): ([HTTPConnection], NWListener?) = lock.withLock {
            stopped = true
            let c = Array(connections.values)
            connections.removeAll()
            streams.removeAll()
            let l = listener
            listener = nil
            return (c, l)
        }
        l?.cancel()
        heartbeat?.cancel()
        heartbeat = nil
        for c in open { c.close() }
        pairing.revokeAll()
        port = nil
        queue.asyncAfter(deadline: .now() + 0.5) { [store] in
            store.discardIncomplete()
            store.saveHashes()
        }
    }

    private func listen(on candidate: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if configuration.loopbackOnly {
            parameters.requiredInterfaceType = .loopback
        } else {
            parameters.prohibitedInterfaceTypes = [.cellular]
        }
        let requested: NWEndpoint.Port = candidate == 0 ? .any : (NWEndpoint.Port(rawValue: candidate) ?? .any)
        let listener = try NWListener(using: parameters, on: requested)
        if configuration.advertise {
            listener.service = NWListener.Service(name: configuration.serviceName, type: Self.serviceType,
                                                  txtRecord: NWTXTRecord(["path": "/"]))
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) } else { self?.listenerFailed(error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
        return port
    }

    private func listenerFailed(_ error: NWError) {
        host.onEvent(.failed(error.localizedDescription))
        stop()
    }

    private func accept(_ nw: NWConnection) {
        let connection = HTTPConnection(nw, route: { [weak self] head, conn in
            self?.route(head, conn) ?? .respond(.error(503, "the server is stopping"))
        }, onClosed: { [weak self] conn in
            self?.lock.withLock { _ = self?.connections.removeValue(forKey: ObjectIdentifier(conn)) }
        })
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        if accepted { connection.start() } else { nw.cancel() }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let open = self.lock.withLock { self.streams.values.filter { !$0.text }.map(\.stream) }
            for s in open { s.write(": ping\n\n") }
            self.publishSessions()
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - Routing

    func route(_ head: HTTPRequestHead, _ connection: HTTPConnection) -> HTTPRoute {
        let path = head.path
        guard path.hasPrefix("/api/") else {
            guard head.method == "GET" || head.method == "HEAD" else { return .respond(.error(405, "method not allowed")) }
            return .respond(staticFile(path))
        }
        // A page on another site can't drive this through the visitor's browser.
        if head.method != "GET", let origin = head.header("origin"), !originMatches(origin, host: head.header("host")) {
            return .respond(.error(403, "requests from other sites are refused"))
        }
        if path == "/api/pair" {
            guard head.method == "POST" else { return .respond(.error(405, "POST a {\"pin\": \"123456\"}")) }
            return .buffered(limit: 1024) { [weak self] body in self?.pair(body) ?? .error(503, "stopping") }
        }
        // Either credential; a cookie left by an earlier server lifetime
        // (cookies ignore the port) mustn't shadow a valid bearer token.
        guard let token = [head.cookie(Self.cookieName), Self.bearer(head)].compactMap({ $0 })
            .first(where: { pairing.validate($0) }) else {
            return .respond(.error(401, "enter the PIN shown in LambdaVision"))
        }
        switch (head.method, path) {
        case ("GET", "/api/status"):
            return .buffered(limit: 0) { [weak self] _ in await self?.status() ?? .error(503, "stopping") }
        case ("GET", "/api/library"):
            return .buffered(limit: 0) { [weak self] _ in await self?.libraryResponse() ?? .error(503, "stopping") }
        case ("GET", "/api/space"):
            return .respond(.json(200, space()))
        case ("POST", "/api/active"):
            return .buffered(limit: 4096) { [weak self] body in await self?.setActive(body) ?? .error(503, "stopping") }
        case ("POST", "/api/delete"):
            return .buffered(limit: 4096) { [weak self] body in self?.delete(body) ?? .error(503, "stopping") }
        case ("GET", "/api/manifest"):
            return .buffered(limit: 0) { [weak self] _ in self?.manifest(head) ?? .error(503, "stopping") }
        case ("PUT", "/api/upload"), ("POST", "/api/upload"):
            return uploadRoute(head)
        case ("POST", "/api/upload/plan"):
            return .buffered(limit: 4096) { [weak self] body in self?.plan(body) ?? .error(503, "stopping") }
        case ("DELETE", "/api/staging"), ("POST", "/api/staging/discard"):
            return .respond(discardStaging())
        case ("POST", "/api/commit"):
            if head.query["stream"] == "text" {
                return .stream(contentType: "text/plain; charset=utf-8") { [weak self] stream in
                    self?.commitStreaming(stream, token: token)
                }
            }
            return .buffered(limit: 4096) { [weak self] _ in await self?.commit() ?? .error(503, "stopping") }
        case ("PUT", "/api/upload-zip"), ("POST", "/api/upload-zip"):
            return zipRoute(head)
        case ("GET", "/api/events"):
            return .stream(contentType: "text/event-stream") { [weak self] stream in self?.openEvents(stream, token: token) }
        default:
            return .respond(.error(404, "no such endpoint: \(head.method) \(path)"))
        }
    }

    static func bearer(_ head: HTTPRequestHead) -> String? {
        guard let auth = head.header("authorization"), auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }

    func originMatches(_ origin: String, host: String?) -> Bool {
        guard let host, let url = URL(string: origin), let originHost = url.host else { return false }
        let originAuthority = url.port.map { "\(originHost):\($0)" } ?? originHost
        return originAuthority.lowercased() == host.lowercased()
    }

    static func jsonBody(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    // MARK: Pairing

    private func pair(_ body: Data) -> HTTPResponse {
        let pin = (Self.jsonBody(body)["pin"] as? String) ?? String(decoding: body, as: UTF8.self)
        switch pairing.attempt(pin) {
        case .paired(let token):
            publishSessions()
            var r = HTTPResponse.json(200, ["ok": true, "token": token])
            r.headers.append(("Set-Cookie", "\(Self.cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict"))
            return r
        case .wrong(let regenerated):
            let message = regenerated
                ? "Too many wrong PINs. LambdaVision is showing a new one; try again in \(Int(pairing.policy.lockout)) seconds."
                : "That PIN isn't right. Check the number shown in LambdaVision."
            return .error(401, message, extra: ["regenerated": regenerated])
        case .tooSoon(let wait):
            var r = HTTPResponse.error(429, "Wait \(wait) second\(wait == 1 ? "" : "s") before trying again.", extra: ["retryAfter": wait])
            r.headers.append(("Retry-After", "\(wait)"))
            return r
        }
    }

    // MARK: Library

    /// Lowercased gamedirs the running engine reads from.
    func protectedGamedirs(_ scan: LibraryScan? = nil) -> Set<String> {
        guard let running = host.runningGame() else { return [] }
        let games = (scan ?? configuration.library.refresh().scan).games
        return running.dirsInUse(root: configuration.library.root.path, library: games)
    }

    static func isProtected(_ gamedir: String, in set: Set<String>) -> Bool {
        let lower = gamedir.lowercased()
        if set.contains(lower) { return true }
        if let base = GameScanner.overlayBase(of: lower), set.contains(base) { return true }
        return false
    }

    func space() -> [String: Any] {
        let root = configuration.library.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return ["free": GameImporter.availableCapacity(at: root) ?? 0, "total": values?.volumeTotalCapacity ?? 0]
    }

    private func status() async -> HTTPResponse {
        let staged = store.stagedSummary()
        let u = uploadProgress
        return .json(200, [
            "sessions": sessionCount(),
            "importing": isImporting,
            "staged": ["files": staged.files, "bytes": staged.bytes, "gamedirs": staged.gamedirs],
            "upload": Self.json(u),
            "space": space(),
            "running": host.runningGame()?.gamedir as Any,
            "log": recentLog.suffix(100).map(Self.json),
        ])
    }

    private func libraryResponse() async -> HTTPResponse {
        let refresh = configuration.library.refresh()
        let protected = protectedGamedirs(refresh.scan)
        let active = await host.activeGamedir()?.lowercased()
        let root = configuration.library.root
        let chosen = active.flatMap { a in refresh.scan.games.first { $0.gamedir.lowercased() == a } }
            ?? refresh.scan.games.first { $0.kind == .base } ?? refresh.scan.games.first
        let games: [[String: Any]] = refresh.scan.games.map { g in
            let dirs = [g.gamedir] + g.overlays
            let size = dirs.reduce(Int64(0)) { $0 + GameImporter.treeSize(root.appendingPathComponent($1)) }
            return [
                "gamedir": g.gamedir,
                "title": g.title,
                "kind": g.kind.rawValue,
                "kindLabel": ImportLog.kindLabel(g.kind),
                "kindReason": g.kindReason,
                "overlays": g.overlays,
                "hdOverlay": g.hdOverlay as Any,
                "size": size,
                "warnings": g.warnings.map { ["code": ImportLog.code($0), "text": ImportLog.describe($0)] },
                "active": g.gamedir == chosen?.gamedir,
                "inUse": Self.isProtected(g.gamedir, in: protected),
                "fallbackDir": g.info.fallbackDir as Any,
            ]
        }
        let orphans: [[String: Any]] = refresh.scan.orphanOverlays.map { o in
            ["gamedir": o, "size": GameImporter.treeSize(root.appendingPathComponent(o)),
             "inUse": Self.isProtected(o, in: protected)]
        }
        return .json(200, ["games": games, "orphanOverlays": orphans, "space": space(),
                           "running": host.runningGame()?.gamedir as Any, "importing": isImporting])
    }

    private func setActive(_ body: Data) async -> HTTPResponse {
        guard let gamedir = Self.jsonBody(body)["gamedir"] as? String else { return .error(400, "send {\"gamedir\": \"...\"}") }
        guard let game = configuration.library.refresh().scan.game(gamedir) else { return .error(404, "\(gamedir) isn't installed") }
        let note = await host.setActive(game.gamedir)
        publish("library", [:])
        return .json(200, ["ok": true, "gamedir": game.gamedir, "note": note as Any])
    }

    private func delete(_ body: Data) -> HTTPResponse {
        let json = Self.jsonBody(body)
        guard let name = json["gamedir"] as? String, UploadStore.isGamedirName(name) else {
            return .error(400, "send {\"gamedir\": \"...\"}")
        }
        if isImporting { return .error(409, "An import is running; delete when it has finished.") }
        let fm = FileManager.default
        let root = configuration.library.root
        let refresh = configuration.library.refresh()
        let protected = protectedGamedirs(refresh.scan)
        let onDisk = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        guard let real = onDisk.first(where: { $0.lowercased() == name.lowercased() }) else {
            return .error(404, "\(name) isn't installed")
        }
        var targets = [real]
        if json["overlays"] as? Bool ?? true, let game = refresh.scan.game(real) { targets += game.overlays }
        for t in targets where Self.isProtected(t, in: protected) {
            return .error(409, "\(t) is in use by the running game. Reopen LambdaVision to delete it.")
        }
        var removed: [String] = []
        for t in targets {
            let path = root.appendingPathComponent(t).path
            // Never follow a symlink out of GameData.
            guard (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory else { continue }
            do { try fm.removeItem(atPath: path); removed.append(t) } catch {
                return .error(500, "Couldn't delete \(t).")
            }
        }
        _ = configuration.library.refresh()
        appendLog("Deleted \(removed.joined(separator: ", "))", .info)
        host.onEvent(.libraryChanged)
        publish("library", [:])
        return .json(200, ["ok": true, "deleted": removed])
    }

    // MARK: Manifests

    /// Installed and staged files of one gamedir: `{gamedir, installed,
    /// files: [...], staged: [...]}`, or with `format=tsv` one line per file:
    /// `where<TAB>size<TAB>mtime<TAB>sha256<TAB>path`, where is `i` or `s`.
    private func manifest(_ head: HTTPRequestHead) -> HTTPResponse {
        guard let name = head.query["gamedir"], UploadStore.isGamedirName(name) else {
            return .error(400, "pass ?gamedir=<folder>")
        }
        let withHashes = head.query["hashes"] != "0"
        let root = configuration.library.root
        let real = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .first { $0.lowercased() == name.lowercased() }
        var installed: [ManifestFile] = []
        if let real {
            let dir = root.appendingPathComponent(real)
            if (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeDirectory {
                installed = store.manifest(of: dir, hashes: withHashes)
            }
        }
        let staged = store.stagedDir(name).map { store.manifest(of: $0, hashes: withHashes) } ?? []
        store.saveHashes()
        if head.query["format"] == "tsv" {
            var out = ""
            func line(_ w: String, _ f: ManifestFile) {
                guard !f.path.contains("\t"), !f.path.contains("\n") else { return }
                out += "\(w)\t\(f.size)\t\(Int(f.mtime))\t\(f.sha256 ?? "-")\t\(f.path)\n"
            }
            installed.forEach { line("i", $0) }
            staged.forEach { line("s", $0) }
            return .text(200, out, type: "text/tab-separated-values; charset=utf-8")
        }
        func encode(_ f: ManifestFile) -> [String: Any] {
            ["path": f.path, "size": f.size, "mtime": f.mtime, "sha256": f.sha256 as Any]
        }
        return .json(200, ["gamedir": real ?? name, "installed": real != nil,
                           "inUse": Self.isProtected(name, in: protectedGamedirs()),
                           "files": installed.map(encode), "staged": staged.map(encode)])
    }

    // MARK: Uploads

    private func uploadRoute(_ head: HTTPRequestHead) -> HTTPRoute {
        guard let raw = head.query["path"] ?? head.header("x-path").flatMap({ $0.removingPercentEncoding }) else {
            return .respond(.error(400, "pass ?path=<gamedir>/<file>"))
        }
        let split: (gamedir: String, relative: String)?
        do { split = try UploadStore.split(raw) } catch let e as HTTPError {
            return .respond(.error(e.status, e.message))
        } catch {
            return .respond(.error(422, "unsafe path: \(raw)"))
        }
        guard let split else { return .respond(.json(200, ["skipped": true, "reason": "junk file"])) }
        if isImporting { return .respond(.error(409, "An import is running; upload again when it has finished.")) }
        if Self.isProtected(split.gamedir, in: protectedGamedirs()) {
            return .respond(.error(409, "\(split.gamedir) is in use by the running game. Reopen LambdaVision, then upload before starting the game."))
        }
        if let free = GameImporter.availableCapacity(at: configuration.library.root), Int64(head.contentLength) > free {
            return .respond(.error(507, "Not enough space on the headset."))
        }
        let mtime = head.query["mtime"].flatMap(Double.init)
        let sha = head.query["sha256"] ?? head.header("x-sha256")
        do {
            lock.withLock { upload.activeUploads += 1 }
            let sink = try store.fileSink(
                gamedir: split.gamedir, relative: split.relative, size: head.contentLength, mtime: mtime, sha256: sha,
                progress: { [weak self] n in self?.uploadBytes(n) },
                completed: { [weak self] ok in self?.uploadEnded(ok, size: head.contentLength) })
            return .streamed(sink)
        } catch {
            lock.withLock { upload.activeUploads -= 1 }
            return .respond(.error(500, "couldn't start the upload"))
        }
    }

    private func uploadBytes(_ n: Int) {
        let emit: UploadProgress? = lock.withLock {
            upload.receivedBytes += Int64(n)
            guard Date().timeIntervalSince(lastUploadEvent) > 0.25 else { return nil }
            lastUploadEvent = Date()
            return upload
        }
        if let emit { publishUpload(emit) }
    }

    private func uploadEnded(_ ok: Bool, size: Int) {
        let snapshot: UploadProgress = lock.withLock {
            upload.activeUploads -= 1
            if ok { upload.completedFiles += 1 } else {
                upload.failedFiles += 1
                upload.receivedBytes = max(0, upload.receivedBytes - Int64(size))   // will be sent again
            }
            lastUploadEvent = Date()
            return upload
        }
        publishUpload(snapshot)
    }

    private func publishUpload(_ u: UploadProgress) {
        host.onEvent(.upload(u))
        publish("upload", Self.json(u))
    }

    private func plan(_ body: Data) -> HTTPResponse {
        let json = Self.jsonBody(body)
        let snapshot: UploadProgress = lock.withLock {
            let active = upload.activeUploads
            upload = UploadProgress(plannedFiles: json["files"] as? Int ?? 0,
                                    plannedBytes: (json["bytes"] as? NSNumber)?.int64Value ?? 0,
                                    activeUploads: active)
            return upload
        }
        publishUpload(snapshot)
        return .json(200, ["ok": true])
    }

    private func discardStaging() -> HTTPResponse {
        if isImporting { return .error(409, "An import is running.") }
        store.clearTree()
        appendLog("Discarded the unfinished upload.", .info)
        publish("library", [:])
        return .json(200, ["ok": true])
    }

    private func zipRoute(_ head: HTTPRequestHead) -> HTTPRoute {
        if isImporting { return .respond(.error(409, "An import is running; send the zip when it has finished.")) }
        guard head.contentLength > 0 else { return .respond(.error(411, "send the zip with Content-Length")) }
        if let free = GameImporter.availableCapacity(at: configuration.library.root), Int64(head.contentLength) * 2 > free {
            return .respond(.error(507, "Not enough space on the headset to unpack this zip."))
        }
        let name = head.query["name"] ?? "upload.zip"
        do {
            lock.withLock { upload = UploadProgress(plannedFiles: 1, plannedBytes: Int64(head.contentLength), activeUploads: 1) }
            let sink = try store.zipSink(name: name, size: head.contentLength) { [weak self] url in
                guard let self else { return }
                self.uploadEnded(url != nil, size: head.contentLength)
                if let url {
                    Task { await self.runImport(.zip(url, deleteWhenDone: true), label: (name as NSString).lastPathComponent) }
                }
            }
            return .streamed(ProgressSink(sink) { [weak self] n in self?.uploadBytes(n) })
        } catch {
            return .respond(.error(500, "couldn't start the upload"))
        }
    }

    // MARK: Importing

    private func commit() async -> HTTPResponse {
        if store.isEmpty { return .error(409, "Nothing has been uploaded yet.") }
        guard await host.mayImport() else { return .error(409, "LambdaVision is importing something else; try again in a moment.") }
        guard claimImport() else { return .error(409, "An import is already running.") }
        Task { await self.runImport(.directory(store.tree, consume: true), label: "the uploaded files", claimed: true) }
        return .json(202, ["ok": true, "started": true])
    }

    private func commitStreaming(_ stream: HTTPStream, token: String) {
        lock.withLock { streams[stream.id] = (stream, token, true) }
        stream.onClose = { [weak self] in self?.lock.withLock { _ = self?.streams.removeValue(forKey: stream.id) } }
        Task {
            if store.isEmpty { stream.write("Nothing has been uploaded yet.\n"); stream.close(); return }
            guard await host.mayImport(), claimImport() else {
                stream.write("Another import is running; try again in a moment.\n"); stream.close(); return
            }
            await runImport(.directory(store.tree, consume: true), label: "the uploaded files", claimed: true)
            stream.close()
        }
    }

    private func claimImport() -> Bool {
        let claimed = lock.withLock { () -> Bool in
            guard !importing else { return false }
            importing = true
            return true
        }
        if claimed { host.onEvent(.importing(true)); publish("importing", ["importing": true]) }
        return claimed
    }

    func runImport(_ source: ImportSource, label: String, claimed: Bool = false) async {
        if !claimed {
            guard await host.mayImport(), claimImport() else {
                appendLog("Another import is running; send it again in a moment.", .error)
                if case .zip(let url, _) = source { try? FileManager.default.removeItem(at: url) }
                return
            }
        }
        var options = ImportOptions()
        options.protectedGamedirs = protectedGamedirs()
        appendLog("Importing \(label)…", .info)
        let lastFraction = FractionBox()
        do {
            try FileManager.default.createDirectory(at: configuration.importStagingRoot, withIntermediateDirectories: true)
            _ = try await importer.run(source, options: options) { [weak self] event in
                guard let self else { return }
                if case .progress(let done, let total) = event {
                    let f = total > 0 ? Double(done) / Double(total) : 0
                    if lastFraction.advance(to: f) || done == total {
                        self.host.onEvent(.importProgress(f))
                        self.publish("importProgress", ["fraction": f])
                    }
                    return
                }
                if let (text, level) = ImportLog.describe(event) { self.appendLog(text, level) }
            }
            if case .directory = source { store.clearTree() }
        } catch {
            appendLog(ImportLog.describe(error), .error)
        }
        if case .zip(let url, _) = source { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        lock.withLock { importing = false }
        host.onEvent(.importProgress(nil))
        host.onEvent(.importing(false))
        host.onEvent(.libraryChanged)
        publish("importing", ["importing": false])
        publish("library", [:])
    }

    // MARK: Events

    private func openEvents(_ stream: HTTPStream, token: String) {
        lock.withLock { streams[stream.id] = (stream, token, false) }
        stream.onClose = { [weak self] in
            self?.lock.withLock { _ = self?.streams.removeValue(forKey: stream.id) }
            self?.publishSessions()
        }
        stream.write("retry: 3000\n\n")
        stream.event("hello", json: ["log": recentLog.suffix(100).map(Self.json), "importing": isImporting,
                                     "upload": Self.json(uploadProgress)])
        publishSessions()
    }

    private func publish(_ name: String, _ object: [String: Any]) {
        let open = lock.withLock { streams.values.filter { !$0.text }.map(\.stream) }
        for s in open { s.event(name, json: object) }
    }

    func appendLog(_ text: String, _ level: LogLine.Level) {
        let (line, textStreams): (LogLine, [HTTPStream]) = lock.withLock {
            let line = LogLine(id: nextLogID, text: text, level: level)
            nextLogID += 1
            log.append(line)
            if log.count > 300 { log.removeFirst(log.count - 300) }
            return (line, streams.values.filter(\.text).map(\.stream))
        }
        host.onEvent(.log(line))
        publish("log", Self.json(line))
        let prefix = level == .warning ? "warning: " : level == .error ? "error: " : ""
        for s in textStreams { s.write(prefix + text + "\n") }
    }

    /// Paired clients with the page open, or that made a request lately.
    func sessionCount() -> Int {
        let streaming = lock.withLock { Set(streams.values.filter { !$0.text }.map(\.token)) }
        return streaming.union(pairing.activeTokens(within: 30)).count
    }

    private func publishSessions() {
        let n = sessionCount()
        let changed = lock.withLock { () -> Bool in
            defer { lastSessionCount = n }
            return lastSessionCount != n
        }
        if changed { host.onEvent(.sessions(n)) }
    }

    static func json(_ line: LogLine) -> [String: Any] {
        ["id": line.id, "text": line.text, "level": line.level.rawValue]
    }

    static func json(_ u: UploadProgress) -> [String: Any] {
        ["plannedFiles": u.plannedFiles, "plannedBytes": u.plannedBytes, "completedFiles": u.completedFiles,
         "receivedBytes": u.receivedBytes, "activeUploads": u.activeUploads, "failedFiles": u.failedFiles]
    }

    // MARK: Static files

    static let contentTypes = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "wasm": "application/wasm", "svg": "image/svg+xml",
        "json": "application/json", "txt": "text/plain; charset=utf-8", "png": "image/png",
    ]

    var webRoot: URL? { configuration.webRoot ?? Bundle.module.url(forResource: "Web", withExtension: nil) }

    private func staticFile(_ path: String) -> HTTPResponse {
        let rel = path == "/" ? "index.html" : String(path.dropFirst())
        guard let webRoot, let safe = try? GameImporter.safeRelativePath(rel), !safe.isEmpty else {
            return .error(404, "not found")
        }
        let file = webRoot.appendingPathComponent(safe)
        guard file.path.hasPrefix(webRoot.path + "/"), let data = FileManager.default.contents(atPath: file.path) else {
            return .error(404, "not found")
        }
        let ext = file.pathExtension.lowercased()
        var r = HTTPResponse(status: 200, contentType: Self.contentTypes[ext] ?? "application/octet-stream", body: data)
        if ext == "html" {
            r.headers.append(("Content-Security-Policy",
                              "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:; "
                              + "style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; "
                              + "frame-ancestors 'none'; form-action 'self'"))
        }
        return r
    }
}

/// Counts bytes through to another sink.
final class ProgressSink: HTTPBodySink, @unchecked Sendable {
    private let inner: HTTPBodySink
    private let progress: @Sendable (Int) -> Void
    init(_ inner: HTTPBodySink, progress: @escaping @Sendable (Int) -> Void) { self.inner = inner; self.progress = progress }
    func write(_ data: Data) throws { try inner.write(data); progress(data.count) }
    func finish() async -> HTTPResponse {
        let r = await inner.finish()
        return r.status == 200 ? .json(202, ["ok": true, "importing": true]) : r
    }
    func abort() { inner.abort() }
}

/// The last progress fraction reported, so events go out per percent.
final class FractionBox: @unchecked Sendable {
    private var last = -1.0
    private let lock = NSLock()
    func advance(to f: Double) -> Bool {
        lock.withLock {
            guard f - last >= 0.01 else { return false }
            last = f
            return true
        }
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
