import Foundation
import Network

// The HTTP side of the phone server (Phone.swift). Takes has no packages, so this is a small
// HTTP/1.1 server on Network.framework: one request per connection (`Connection: close`), bodies
// with Content-Length or chunked, files with Range, and Server-Sent Events. It listens on
// 127.0.0.1 only; `tailscale serve` puts HTTPS in front of it for the tailnet.

struct PhoneRequest {
    var method: String
    var path: String
    var query: [String: String] = [:]
    /// Names in lower case.
    var headers: [String: String] = [:]
    var body = Data()
    /// An upload: the body went to this file, not into `body`.
    var file: URL?

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// "GET /a/b?c=d HTTP/1.1" and the header lines, without the blank line at the end.
    static func parse(head: String) -> PhoneRequest? {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1") else { return nil }
        guard let parts = URLComponents(string: String(first[1])) else { return nil }
        var r = PhoneRequest(method: String(first[0]).uppercased(), path: parts.path)
        for item in parts.queryItems ?? [] { r.query[item.name] = item.value ?? "" }
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            r.headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return r
    }
}

enum PhoneResponse {
    case json(Data, status: Int = 200)
    case file(URL, type: String)
    case events
    case status(Int, String)

    static func encode<T: Encodable>(_ value: T, status: Int = 200) -> PhoneResponse {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(value) else { return .status(500, "Could not encode the answer") }
        return .json(data, status: status)
    }

    static func error(_ status: Int, _ message: String) -> PhoneResponse {
        encode(["error": message], status: status)
    }
}

/// Decodes `Transfer-Encoding: chunked` as the bytes arrive. Pure, so tests can feed it.
struct ChunkedDecoder {
    private var pending = Data()
    /// Bytes still to read in the current chunk; nil = a size line comes next.
    private var left: Int?
    private(set) var done = false

    /// Returns the body bytes in `data`.
    mutating func feed(_ data: Data) -> Data {
        pending.append(data)
        var out = Data()
        while !done {
            if let n = left {
                if n > 0 {
                    guard !pending.isEmpty else { break }
                    let take = min(n, pending.count)
                    out.append(pending.prefix(take))
                    pending = Data(pending.dropFirst(take))
                    left = n - take
                    if left! > 0 { break }
                }
                // The CRLF after a chunk.
                guard pending.count >= 2 else { break }
                pending = Data(pending.dropFirst(2))
                left = nil
            } else {
                guard let end = pending.range(of: Data("\r\n".utf8)) else { break }
                let line = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
                pending = Data(pending[end.upperBound...])
                let hex = line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(hex, radix: 16) else { done = true; break }
                if size == 0 { done = true; break }  // trailers are ignored
                left = size
            }
        }
        return out
    }
}

/// Things a connection asks of the server.
protocol PhoneHandler: AnyObject, Sendable {
    /// Before an upload body arrives: where to write it, or the error to send at once.
    func uploadTarget(_ req: PhoneRequest) -> Result<URL, PhoneError>
    func respond(_ req: PhoneRequest) async -> PhoneResponse
    func eventsOpened(_ c: PhoneConnection)
    func eventsClosed(_ c: PhoneConnection)
}

struct PhoneError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

final class PhoneConnection: @unchecked Sendable {
    static let maxBody = 4 << 20
    /// Open connections keep themselves alive here until they close.
    private static var live: [ObjectIdentifier: PhoneConnection] = [:]
    private static let liveLock = NSLock()
    private let conn: NWConnection
    private let queue: DispatchQueue
    private weak var handler: PhoneHandler?
    private var buffer = Data()
    private var request: PhoneRequest?
    private var remaining = 0
    private var chunked: ChunkedDecoder?
    private var upload: FileHandle?
    private(set) var closed = false

    init(_ conn: NWConnection, handler: PhoneHandler) {
        self.conn = conn
        self.handler = handler
        queue = DispatchQueue(label: "takes.phone.conn")
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        Self.liveLock.withLock { Self.live[ObjectIdentifier(self)] = self }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, end, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.take(data) }
            if error != nil || (end && self.request == nil) { self.close(); return }
            if end, self.request != nil, self.remaining > 0 || (self.chunked.map { !$0.done } ?? false) {
                self.close(); return  // the body was cut off
            }
            if !self.closed && !self.handed { self.receive() }
        }
    }

    private var handed = false

    private func take(_ data: Data) {
        guard request != nil else {
            buffer.append(data)
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 << 10 { finish(.status(431, "Headers too large")) }
                return
            }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            let rest = Data(buffer[end.upperBound...])
            buffer = Data()
            guard var req = PhoneRequest.parse(head: head) else { finish(.status(400, "Bad request")); return }
            if req.header("transfer-encoding")?.lowercased().contains("chunked") == true {
                chunked = ChunkedDecoder()
            } else {
                remaining = Int(req.header("content-length") ?? "0") ?? 0
            }
            if req.method == "PUT" {
                guard let handler else { close(); return }
                switch handler.uploadTarget(req) {
                case .failure(let e): finish(.error(e.status, e.message)); return
                case .success(let url):
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    guard let h = try? FileHandle(forWritingTo: url) else { finish(.error(500, "Can't write the file")); return }
                    upload = h
                    req.file = url
                }
            } else if remaining > Self.maxBody {
                finish(.status(413, "Too large")); return
            }
            request = req
            if !rest.isEmpty { body(rest) } else if remaining == 0 && chunked == nil { complete() }
            return
        }
        body(data)
    }

    private func body(_ data: Data) {
        var bytes = data
        if chunked != nil {
            bytes = chunked!.feed(data)
        } else {
            if bytes.count > remaining { bytes = bytes.prefix(remaining) }
            remaining -= bytes.count
        }
        if let upload {
            upload.write(bytes)
        } else {
            request?.body.append(bytes)
            if (request?.body.count ?? 0) > Self.maxBody { finish(.status(413, "Too large")); return }
        }
        if chunked?.done ?? (remaining == 0) { complete() }
    }

    private func complete() {
        guard let req = request, !handed, let handler else { return }
        handed = true
        try? upload?.close()
        upload = nil
        Task { [weak self] in
            let res = await handler.respond(req)
            self?.queue.async { self?.finish(res) }
        }
    }

    // MARK: Sending

    private func finish(_ res: PhoneResponse) {
        handed = true
        switch res {
        case .json(let data, let status):
            send(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
        case .status(let code, let text):
            send(status: code, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        case .file(let url, let type):
            sendFile(url, type: type)
        case .events:
            let head = Self.head(200, ["Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                                       "X-Accel-Buffering": "no"], length: nil)
            conn.send(content: head + Data(": open\n\n".utf8), completion: .contentProcessed { [weak self] e in
                guard let self else { return }
                if e != nil { self.close(); return }
                self.handler?.eventsOpened(self)
            })
        }
    }

    /// One Server-Sent Event. Safe from any thread.
    func event(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            conn.send(content: Data("data: ".utf8) + data + Data("\n\n".utf8), completion: .contentProcessed { [weak self] e in
                if e != nil { self?.close() }
            })
        }
    }

    static func head(_ status: Int, _ headers: [String: String], length: Int?) -> Data {
        var s = "HTTP/1.1 \(status) \(reason(status))\r\n"
        var all = headers
        if let length { all["Content-Length"] = "\(length)" }
        all["Connection"] = length == nil ? "keep-alive" : "close"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    static func reason(_ s: Int) -> String {
        [200: "OK", 206: "Partial Content", 304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
         404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 416: "Range Not Satisfiable",
         431: "Request Header Fields Too Large", 500: "Internal Server Error"][s] ?? "Status"
    }

    private func send(status: Int, headers: [String: String], body: Data) {
        conn.send(content: Self.head(status, headers, length: body.count) + body, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    /// An HTTP date ("Thu, 08 Oct 2026 17:48:00 GMT"), whole seconds, as Last-Modified wants it.
    static func httpDate(_ d: Date) -> String { httpDates.string(from: d) }
    private static let httpDates: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    /// "bytes=0-1023", "bytes=500-", "bytes=-500" → the closed range in a file of `size` bytes.
    static func range(_ header: String?, size: Int64) -> ClosedRange<Int64>?? {
        guard let header, header.hasPrefix("bytes="), size > 0 else { return .some(nil) }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard ends.count == 2 else { return .some(nil) }
        if ends[0].isEmpty {
            guard let n = Int64(ends[1]), n > 0 else { return nil }
            return .some(max(0, size - n)...(size - 1))
        }
        guard let a = Int64(ends[0]), a < size else { return nil }
        let b = ends[1].isEmpty ? size - 1 : min(Int64(ends[1]) ?? size - 1, size - 1)
        guard b >= a else { return nil }
        return .some(a...b)
    }

    private func sendFile(_ url: URL, type: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let h = try? FileHandle(forReadingFrom: url), let size = (attrs?[.size] as? NSNumber)?.int64Value else {
            send(status: 404, headers: [:], body: Data("No such file".utf8)); return
        }
        // The phone keeps pictures on disk and asks "changed since?": unchanged costs one empty answer.
        let modified = (attrs?[.modificationDate] as? Date).map(Self.httpDate)
        if let modified, request?.header("range") == nil, request?.header("if-modified-since") == modified {
            try? h.close()
            send(status: 304, headers: ["Last-Modified": modified, "Cache-Control": "private, max-age=60"], body: Data()); return
        }
        guard let r = Self.range(request?.header("range"), size: size) else {
            try? h.close()
            send(status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data()); return
        }
        let span = r ?? 0...(max(size, 1) - 1)
        let length = size == 0 ? 0 : span.upperBound - span.lowerBound + 1
        var headers = ["Content-Type": type, "Accept-Ranges": "bytes", "Cache-Control": "private, max-age=60"]
        if let modified { headers["Last-Modified"] = modified }
        if r != nil { headers["Content-Range"] = "bytes \(span.lowerBound)-\(span.upperBound)/\(size)" }
        let head = Self.head(r != nil ? 206 : 200, headers, length: Int(length))
        if request?.method == "HEAD" || length == 0 {
            try? h.close()
            conn.send(content: head, completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }
        try? h.seek(toOffset: UInt64(span.lowerBound))
        conn.send(content: head, completion: .contentProcessed { [weak self] e in
            guard e == nil else { try? h.close(); self?.close(); return }
            self?.pump(h, left: length)
        })
    }

    private func pump(_ h: FileHandle, left: Int64) {
        guard left > 0, !closed else { try? h.close(); close(); return }
        let chunk = (try? h.read(upToCount: Int(min(left, 1 << 20)))) ?? Data()
        guard !chunk.isEmpty else { try? h.close(); close(); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] e in
            guard e == nil else { try? h.close(); self?.close(); return }
            self?.pump(h, left: left - Int64(chunk.count))
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? upload?.close()
        if let f = request?.file, !handed { try? FileManager.default.removeItem(at: f) }
        handler?.eventsClosed(self)
        conn.cancel()
        Self.liveLock.withLock { Self.live[ObjectIdentifier(self)] = nil }
    }
}

final class PhoneListener: @unchecked Sendable {
    private var listener: NWListener?
    private let handler: PhoneHandler

    init(handler: PhoneHandler) { self.handler = handler }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [handler] c in PhoneConnection(c, handler: handler).start() }
        l.start(queue: DispatchQueue(label: "takes.phone.listen"))
        listener = l
    }

    var port: UInt16? { listener?.port?.rawValue }

    func stop() { listener?.cancel(); listener = nil }
}
