//
//  HTTP.swift
//  GameLibraryServer
//
//  Just enough HTTP/1.1 for the page, curl and push-assets.sh, on
//  Network.framework. Modeled on DebugTraceServer's HTTPMessage (one request
//  per connection, `Connection: close`, Content-Length bodies only), with
//  the one thing it can't do: bodies are handed to a sink chunk by chunk as
//  they arrive, so a 500 MB upload never sits in memory. The next chunk is
//  only read once the sink has written the last one, which is the back
//  pressure. Responses are either whole, or a stream left open (server-sent
//  events, the live import log).
//

import Foundation
import Network

/// A request's line and headers; the body, if any, arrives separately.
struct HTTPRequestHead: Sendable {
    let method: String
    /// Percent-decoded, without the query.
    let path: String
    let query: [String: String]
    /// Lowercased names.
    let headers: [String: String]
    let contentLength: Int

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The value of one cookie.
    func cookie(_ name: String) -> String? {
        guard let raw = header("cookie") else { return nil }
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == name { return kv[1] }
        }
        return nil
    }
}

enum HTTPHeadParse {
    case needMore
    /// The head, and how many bytes of the buffer it used.
    case complete(HTTPRequestHead, consumed: Int)
    case invalid(status: Int, message: String)
}

enum HTTPParser {
    static let maxHeaderBytes = 32 * 1024
    private static let separator = Data("\r\n\r\n".utf8)

    static func parseHead(_ buffer: Data) -> HTTPHeadParse {
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431, message: "request header too large") : .needMore
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid(status: 400, message: "malformed request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid(status: 411, message: "chunked bodies are not supported; send Content-Length")
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            return .invalid(status: 400, message: "bad Content-Length")
        }
        let target = String(requestLine[1])
        let components = URLComponents(string: "http://x" + (target.hasPrefix("/") ? target : "/" + target))
        var query: [String: String] = [:]
        for item in components?.percentEncodedQueryItems ?? [] {
            query[formDecode(item.name)] = item.value.map(formDecode) ?? ""
        }
        let path = components?.percentEncodedPath.removingPercentEncoding ?? "/"
        let consumed = end.upperBound - buffer.startIndex
        return .complete(HTTPRequestHead(method: String(requestLine[0]).uppercased(), path: path.isEmpty ? "/" : path,
                                         query: query, headers: headers, contentLength: length), consumed: consumed)
    }

    /// `+` is a space, `%2B` a plus, as in HTML forms and curl --data-urlencode.
    static func formDecode(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [(String, String)] = []

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    /// `{"error": message}` — what the page shows.
    static func error(_ status: Int, _ message: String, extra: [String: Any] = [:]) -> HTTPResponse {
        var object = extra
        object["error"] = message
        return json(status, object)
    }

    static func text(_ status: Int, _ text: String, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: type, body: Data(text.utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += Self.commonHeaders
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Headers of a response whose body is written as it happens and ends
    /// when the connection closes.
    static func streamHead(contentType: String) -> Data {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
        head += commonHeaders
        head += "X-Accel-Buffering: no\r\nConnection: close\r\n\r\n"
        return Data(head.utf8)
    }

    // No Access-Control-Allow-Origin: other web pages must not read this.
    private static let commonHeaders = "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        + "Referrer-Policy: no-referrer\r\n"

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Status"
        }
    }
}

/// Receives a request body as it arrives. `write` runs on the connection's
/// queue, one chunk at a time; then exactly one of `finish` or `abort`.
protocol HTTPBodySink: AnyObject, Sendable {
    func write(_ data: Data) throws
    /// All of Content-Length arrived.
    func finish() async -> HTTPResponse
    /// The client went away or the server stopped first.
    func abort()
}

/// What the server does with a request, decided from its head.
enum HTTPRoute: Sendable {
    /// Reply now; any body is not read.
    case respond(HTTPResponse)
    /// Read a small body into memory, then reply.
    case buffered(limit: Int, @Sendable (Data) async -> HTTPResponse)
    /// Stream the body to a sink, which makes the reply.
    case streamed(HTTPBodySink)
    /// Keep the connection open and write to it as things happen.
    case stream(contentType: String, @Sendable (HTTPStream) -> Void)
}

/// An open response the server writes to until it closes it.
final class HTTPStream: @unchecked Sendable {
    let id = UUID()
    private let connection: HTTPConnection
    /// Called once when the stream ends, whichever side ended it.
    var onClose: (@Sendable () -> Void)?

    init(connection: HTTPConnection) { self.connection = connection }

    func write(_ text: String) { connection.sendRaw(Data(text.utf8)) }

    /// One server-sent event.
    func event(_ name: String, json object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        write("event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n")
    }

    func close() { connection.close() }
}

/// One client connection: reads the head, routes it, feeds the body, replies.
final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    /// Seconds a client may take to send its head, and stay silent mid-body.
    static let headTimeout: TimeInterval = 15
    static let idleTimeout: TimeInterval = 60

    private let route: @Sendable (HTTPRequestHead, HTTPConnection) -> HTTPRoute
    private let onClosed: @Sendable (HTTPConnection) -> Void
    private var buffer = Data()
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private var sink: HTTPBodySink?
    private var stream: HTTPStream?
    private var closed = false
    private var gotHead = false

    init(_ connection: NWConnection,
         route: @escaping @Sendable (HTTPRequestHead, HTTPConnection) -> HTTPRoute,
         onClosed: @escaping @Sendable (HTTPConnection) -> Void) {
        self.connection = connection
        self.queue = DispatchQueue(label: "GameLibraryServer.connection")
        self.route = route
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                self.queue.async { self.finishClose() }
            default: break
            }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        timer.resume()
        self.timer = timer
        receiveHead()
    }

    /// Ends the connection (from any thread).
    func close() {
        queue.async { [self] in
            guard !closed else { return }
            connection.cancel()
            finishClose()
        }
    }

    func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func checkIdle() {
        // An open event stream is quiet by design; its keep-alives prove the
        // client is still there.
        guard stream == nil else { return }
        let limit = gotHead ? Self.idleTimeout : Self.headTimeout
        if Date().timeIntervalSince(lastActivity) > limit { close() }
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        if let sink { self.sink = nil; sink.abort() }
        if let stream { self.stream = nil; stream.onClose?() }
        onClosed(self)
    }

    private func receiveHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data); self.lastActivity = Date() }
            switch HTTPParser.parseHead(self.buffer) {
            case .needMore:
                if error != nil || isComplete { self.close() } else { self.receiveHead() }
            case .invalid(let status, let message):
                self.respond(.error(status, message))
            case .complete(let head, let consumed):
                self.gotHead = true
                let rest = self.buffer.count > consumed ? Data(self.buffer.dropFirst(consumed)) : Data()
                self.buffer = Data()
                self.handle(head, leftover: rest)
            }
        }
    }

    private func handle(_ head: HTTPRequestHead, leftover: Data) {
        let decision = route(head, self)
        if head.header("expect")?.lowercased() == "100-continue" && head.contentLength > 0 {
            switch decision {
            case .buffered, .streamed: sendRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            default: break
            }
        }
        switch decision {
        case .respond(let response):
            respond(response)
        case .buffered(let limit, let handler):
            guard head.contentLength <= limit else {
                respond(.error(413, "body exceeds \(limit) bytes"))
                return
            }
            readBuffered(remaining: head.contentLength, collected: leftover.prefix(head.contentLength)) { [weak self] body in
                Task { self?.respond(await handler(body)) }
            }
        case .streamed(let sink):
            self.sink = sink
            let first = leftover.prefix(head.contentLength)
            do {
                if !first.isEmpty { try sink.write(Data(first)) }
            } catch {
                failSink(error)
                return
            }
            readStreamed(remaining: head.contentLength - first.count)
        case .stream(let contentType, let open):
            let stream = HTTPStream(connection: self)
            self.stream = stream
            sendRaw(HTTPResponse.streamHead(contentType: contentType))
            open(stream)
            // Notice the client leaving: anything it sends, or EOF, ends it.
            watchForEOF()
        }
    }

    private func readBuffered(remaining: Int, collected: Data, done: @escaping @Sendable (Data) -> Void) {
        let needed = remaining - collected.count
        if needed <= 0 { done(collected); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(needed, 65_536)) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            var collected = collected
            if let data { collected.append(data); self.lastActivity = Date() }
            if collected.count >= remaining { done(collected); return }
            if error != nil || isComplete { self.close(); return }
            self.readBuffered(remaining: remaining, collected: collected, done: done)
        }
    }

    private func readStreamed(remaining: Int) {
        guard let sink else { return }
        if remaining <= 0 {
            self.sink = nil
            Task { [weak self] in self?.respond(await sink.finish()) }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1 << 20)) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, let sink = self.sink else { return }
            var left = remaining
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                let chunk = data.count > left ? data.prefix(left) : data
                do { try sink.write(Data(chunk)) } catch { self.failSink(error); return }
                left -= chunk.count
            }
            if left > 0, error != nil || isComplete {
                self.close()   // aborts the sink
                return
            }
            self.readStreamed(remaining: left)
        }
    }

    private func failSink(_ error: Error) {
        let sink = self.sink
        self.sink = nil
        sink?.abort()
        if let e = error as? HTTPError { respond(.error(e.status, e.message)) } else { respond(.error(500, "\(error)")) }
    }

    private func watchForEOF() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self, !self.closed else { return }
            if isComplete || error != nil { self.close() } else { self.watchForEOF() }
        }
    }

    private func respond(_ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}

/// An error a sink or handler turns into a status.
struct HTTPError: Error {
    var status: Int
    var message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}
