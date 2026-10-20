import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Network
import UniformTypeIdentifiers

/// A tiny HTTP/1.1 server for sharing with browsers on the same network. Nothing goes through the
/// internet: phones and computers connect straight to this Mac.
///
/// Every URL starts with a random token (`http://192.168.1.5:52144/k3J9xQ2m7A8b/`), so only people
/// given the link can reach anything. Each response closes its connection, except event streams,
/// which stay open until either side leaves. Runs only between `start()` and `stop()`.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        /// The path after the token, percent-decoded, always starting with "/".
        let path: String
        let query: [String: String]
        /// Header names are lowercased.
        let headers: [String: String]
        /// The client's IP address.
        let client: String
        /// The body, unless `uploadDestination` streamed it to `bodyFile`.
        var body = Data()
        var bodyFile: URL?

        var userAgent: String { headers["user-agent"] ?? "" }
    }

    struct Response: Sendable {
        enum Body: Sendable {
            case data(Data)
            /// Streamed from disk in chunks. Honors Range requests.
            case file(URL)
            /// Server-sent events: the connection stays open. Send with `send(_:data:to:)` or `broadcast`.
            case events(UUID)
        }

        var status = 200
        var headers: [String: String] = [:]
        var body: Body = .data(Data())

        static func html(_ text: String) -> Response {
            Response(headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"], body: .data(Data(text.utf8)))
        }

        static func text(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: .data(Data(text.utf8)))
        }

        static func json(_ object: some Encodable, status: Int = 200) -> Response {
            let data = (try? JSONEncoder().encode(object)) ?? Data("{}".utf8)
            return Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: .data(data))
        }

        /// A download, saved under `name` by the browser.
        static func file(_ url: URL, name: String? = nil, inline: Bool = false) -> Response {
            let name = name ?? url.lastPathComponent
            let ascii = String(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" && $0.value >= 32 ? Character($0) : "_" })
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? ascii
            return Response(headers: ["Content-Disposition": "\(inline ? "inline" : "attachment"); filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"],
                            body: .file(url))
        }

        static let notFound = text("Not found", status: 404)
    }

    /// Reported while files go up or down, at most every half megabyte or so.
    struct Transfer: Sendable {
        enum State: Sendable { case active, finished, failed }
        let id: UUID
        let client: String
        let userAgent: String
        let name: String
        let isUpload: Bool
        let bytes: Int64
        let total: Int64
        let state: State
    }

    enum ServerError: LocalizedError {
        case couldNotStart(String)
        var errorDescription: String? {
            switch self {
            case .couldNotStart(let reason): "Couldn't start sharing: \(reason)"
            }
        }
    }

    /// Answers every request with the right token. Runs off the main actor.
    typealias Handler = @Sendable (Request) async -> Response

    /// The secret first path component of every URL.
    let token: String
    private let handler: Handler
    /// Asked once a request's headers arrive. Return a file URL to stream the body there (uploads);
    /// nil keeps small bodies in memory.
    var uploadDestination: (@Sendable (Request) -> URL?)?
    var onTransfer: (@Sendable (Transfer) -> Void)?
    /// An event stream closed, because the browser left or the server stopped.
    var onEventStreamClosed: (@Sendable (UUID) -> Void)?
    /// In-memory bodies (JSON, forms) larger than this are refused.
    var maxBodySize = 4 << 20

    private let queue = DispatchQueue(label: "com.fiaxe.toolbox.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var streams: [UUID: EventStream] = [:]
    private var keepAlive: DispatchSourceTimer?
    private(set) var port: UInt16 = 0

    private struct EventStream {
        var connection: NWConnection?
        /// Messages sent before the connection was attached.
        var pending: [Data] = []
    }

    init(token: String = LocalHTTPServer.makeToken(), handler: @escaping Handler) {
        self.token = token
        self.handler = handler
    }

    deinit { stop() }

    var isRunning: Bool { lock.withLock { listener != nil } }

    /// Number of open event streams.
    var eventStreamCount: Int { lock.withLock { streams.values.filter { $0.connection != nil }.count } }

    /// Starts listening on a random port on every interface.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: .any) } catch { throw ServerError.couldNotStart(error.localizedDescription) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: ServerError.couldNotStart(error.localizedDescription)) }
                    else { self?.stop() }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: ServerError.couldNotStart("The listener was cancelled.")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.broadcastRaw(Data(": ping\n\n".utf8)) }
        timer.resume()
        lock.withLock {
            self.listener = listener
            self.port = listener.port?.rawValue ?? 0
            self.keepAlive = timer
        }
    }

    /// Stops listening and closes every connection, event streams included.
    func stop() {
        let (listener, connections, streamIDs, timer) = lock.withLock {
            let result = (self.listener, Array(self.connections.values), Array(streams.keys), keepAlive)
            self.listener = nil
            self.connections = [:]
            streams = [:]
            keepAlive = nil
            return result
        }
        timer?.cancel()
        listener?.cancel()
        connections.forEach { $0.cancel() }
        if listener != nil { streamIDs.forEach { onEventStreamClosed?($0) } }
    }

    // MARK: - Event streams

    /// Registers an event stream before the handler returns `.events(id)`, so nothing broadcast in
    /// between is lost. `initial` is sent first, e.g. a snapshot of the current state.
    func openEventStream(_ id: UUID, initial: [(event: String, data: String)] = []) {
        lock.withLock {
            streams[id, default: EventStream()].pending += initial.map { Self.eventData($0.event, $0.data) }
        }
    }

    func send(_ event: String, data: String, to id: UUID) {
        let message = Self.eventData(event, data)
        let connection: NWConnection? = lock.withLock {
            guard var stream = streams[id] else { return nil }
            if stream.connection == nil { stream.pending.append(message); streams[id] = stream }
            return stream.connection
        }
        connection?.send(content: message, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.closeStream(id) }
        })
    }

    func broadcast(_ event: String, data: String) { broadcastRaw(Self.eventData(event, data)) }

    private func broadcastRaw(_ message: Data) {
        let open: [(UUID, NWConnection)] = lock.withLock {
            var open: [(UUID, NWConnection)] = []
            for (id, stream) in streams {
                if let connection = stream.connection { open.append((id, connection)) } else { streams[id]?.pending.append(message) }
            }
            return open
        }
        for (id, connection) in open {
            connection.send(content: message, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.closeStream(id) }
            })
        }
    }

    private func closeStream(_ id: UUID) {
        let connection: NWConnection?? = lock.withLock { streams.removeValue(forKey: id).map(\.connection) }
        guard let connection else { return }
        connection?.cancel()
        onEventStreamClosed?(id)
    }

    private static func eventData(_ event: String, _ data: String) -> Data {
        let lines = data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)" }.joined(separator: "\n")
        return Data("event: \(event)\n\(lines)\n\n".utf8)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        // Plenty for a room full of phones; refuse floods.
        guard lock.withLock({ () -> Bool in
            guard connections.count < 128 else { return false }
            connections[key] = connection
            return true
        }) else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: key) }
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data(), client: Self.host(of: connection.endpoint))
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data, client: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let rest = Data(buffer[end.upperBound...])
                self.route(connection, head: Data(buffer[..<end.lowerBound]), rest: rest, client: client)
            } else if buffer.count > 32 << 10 {
                self.respond(Response.text("Request headers too large", status: 431), to: connection, request: nil)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer, client: client)
            }
        }
    }

    private func route(_ connection: NWConnection, head: Data, rest: Data, client: String) {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            respond(.text("Bad request", status: 400), to: connection, request: nil); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { respond(.text("Bad request", status: 400), to: connection, request: nil); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = parts[1]
        let rawPath = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        var query: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            for pair in target[target.index(after: questionMark)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
                if let key = kv.first { query[key] = kv.count > 1 ? kv[1] : "" }
            }
        }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard components.first.map(String.init) == token else { respond(.notFound, to: connection, request: nil); return }
        if components.count == 1 {
            respond(Response(status: 301, headers: ["Location": "/\(token)/"]), to: connection, request: nil); return
        }
        var request = Request(method: parts[0].uppercased(), path: "/" + components.dropFirst().joined(separator: "/"),
                              query: query, headers: headers, client: client)
        if headers["transfer-encoding"].map({ $0.lowercased().contains("chunked") }) == true {
            respond(.text("Send a Content-Length", status: 411), to: connection, request: request); return
        }
        let length = Int64(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { respond(.text("Bad Content-Length", status: 400), to: connection, request: request); return }
        if length > 0, let file = uploadDestination?(request) {
            request.bodyFile = file
            receiveUpload(connection, request: request, file: file, length: length, initial: rest)
        } else if length > Int64(maxBodySize) {
            respond(.text("Too large", status: 413), to: connection, request: request)
        } else {
            receiveBody(connection, request: request, length: Int(length), buffer: rest)
        }
    }

    private func receiveBody(_ connection: NWConnection, request: Request, length: Int, buffer: Data) {
        if buffer.count >= length {
            var request = request
            request.body = buffer.prefix(length)
            dispatch(request, on: connection)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count < length, isComplete || error != nil { connection.cancel(); return }
            self?.receiveBody(connection, request: request, length: length, buffer: buffer)
        }
    }

    private func receiveUpload(_ connection: NWConnection, request: Request, file: URL, length: Int64, initial: Data) {
        let id = UUID()
        let name = request.query["name"] ?? file.lastPathComponent
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            respond(.text("Couldn't save the file", status: 500), to: connection, request: request); return
        }
        let report: @Sendable (Int64, Transfer.State) -> Void = { [weak self] bytes, state in
            self?.onTransfer?(Transfer(id: id, client: request.client, userAgent: request.userAgent, name: name,
                                       isUpload: true, bytes: bytes, total: length, state: state))
        }
        let fail: @Sendable () -> Void = {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            report(0, .failed)
            connection.cancel()
        }
        @Sendable func write(_ data: Data, received: Int64) {
            let take = data.prefix(Int(min(Int64(data.count), length - received)))
            do { try handle.write(contentsOf: take) } catch { fail(); return }
            let total = received + Int64(take.count)
            if total / (512 << 10) != received / (512 << 10) { report(total, .active) }
            if total >= length {
                try? handle.close()
                report(total, .finished)
                dispatch(request, on: connection)
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty { write(data, received: total) }
                else if isComplete || error != nil { fail() }
                else { write(Data(), received: total) }
            }
        }
        report(0, .active)
        write(initial, received: 0)
    }

    private func dispatch(_ request: Request, on connection: NWConnection) {
        Task { [weak self, handler] in
            let response = await handler(request)
            self?.respond(response, to: connection, request: request)
        }
    }

    // MARK: - Responses

    private func respond(_ response: Response, to connection: NWConnection, request: Request?) {
        var headers = response.headers
        switch response.body {
        case .data(let data):
            headers["Content-Length"] = "\(data.count)"
            let body = request?.method == "HEAD" ? Data() : data
            connection.send(content: head(response.status, headers) + body, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        case .file(let url):
            sendFile(url, response: response, to: connection, request: request)
        case .events(let id):
            headers["Content-Type"] = "text/event-stream; charset=utf-8"
            headers["Cache-Control"] = "no-store"
            headers["X-Accel-Buffering"] = "no"
            let pending: [Data]? = lock.withLock {
                guard listener != nil else { return nil }
                var stream = streams[id] ?? EventStream()
                let pending = stream.pending
                stream.pending = []
                stream.connection = connection
                streams[id] = stream
                return pending
            }
            guard let pending else { connection.cancel(); return }
            connection.send(content: head(200, headers, keepOpen: true) + Data(": open\n\n".utf8) + pending.reduce(Data(), +),
                            completion: .contentProcessed { [weak self] error in if error != nil { self?.closeStream(id) } })
            watchForClose(connection, stream: id)
        }
    }

    /// Browsers never send anything on an event stream, so any read completing means they left.
    private func watchForClose(_ connection: NWConnection, stream id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { self?.closeStream(id) } else { self?.watchForClose(connection, stream: id) }
        }
    }

    private func sendFile(_ url: URL, response: Response, to connection: NWConnection, request: Request?) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            respond(.notFound, to: connection, request: request); return
        }
        var headers = response.headers
        headers["Accept-Ranges"] = "bytes"
        if headers["Content-Type"] == nil {
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            headers["Content-Type"] = mime.hasPrefix("text/") ? mime + "; charset=utf-8" : mime
        }
        var status = response.status
        var start: Int64 = 0, end = size - 1
        if let range = request?.headers["range"], let parsed = Self.parseRange(range, size: size) {
            (start, end) = parsed
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        } else if request?.headers["range"] != nil {
            try? handle.close()
            respond(Response(status: 416, headers: ["Content-Range": "bytes */\(size)"]), to: connection, request: request); return
        }
        let length = max(end - start + 1, 0)
        headers["Content-Length"] = "\(length)"
        let isPreview = status == 206
        let id = UUID()
        let client = request?.client ?? "", agent = request?.userAgent ?? "", name = url.lastPathComponent
        let report: @Sendable (Int64, Transfer.State) -> Void = { [weak self] bytes, state in
            // Range requests from media players are previews, not downloads.
            guard !isPreview else { return }
            self?.onTransfer?(Transfer(id: id, client: client, userAgent: agent, name: name, isUpload: false, bytes: bytes, total: length, state: state))
        }
        if request?.method == "HEAD" || length == 0 {
            try? handle.close()
            connection.send(content: head(status, headers), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        do { try handle.seek(toOffset: UInt64(start)) } catch { try? handle.close(); connection.cancel(); return }
        report(0, .active)
        @Sendable func next(sent: Int64) {
            let chunk = (try? handle.read(upToCount: Int(min(Int64(256 << 10), length - sent)))) ?? Data()
            let total = sent + Int64(chunk.count)
            let done = chunk.isEmpty || total >= length
            // Each chunk is a complete message; mixing an open default message with the final one stalls the stream.
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil {
                    try? handle.close(); report(total, .failed); connection.cancel()
                } else if done {
                    try? handle.close()
                    report(total, total >= length ? .finished : .failed)
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    if total / (512 << 10) != sent / (512 << 10) { report(total, .active) }
                    next(sent: total)
                }
            })
        }
        connection.send(content: head(status, headers), completion: .contentProcessed { error in
            if error != nil { try? handle.close(); connection.cancel() } else { next(sent: 0) }
        })
    }

    private func head(_ status: Int, _ headers: [String: String], keepOpen: Bool = false) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(key): \(value)\r\n" }
        text += keepOpen ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        text += "X-Content-Type-Options: nosniff\r\n\r\n"
        return Data(text.utf8)
    }

    // MARK: - Helpers

    /// One `bytes=start-end` range (suffix and open-ended forms too), clamped to the file.
    static func parseRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            return (max(size - suffix, 0), size - 1)
        }
        guard let start = Int64(bounds[0]), start < size else { return nil }
        let end = bounds[1].isEmpty ? size - 1 : min(Int64(bounds[1]) ?? -1, size - 1)
        return end >= start ? (start, end) : nil
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    private static func host(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%").first ?? ""
        case .ipv6(let address):
            let text = "\(address)".components(separatedBy: "%").first ?? ""
            return text.hasPrefix("::ffff:") ? String(text.dropFirst(7)) : text
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }

    /// 12 random letters and digits.
    static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<12).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// The Mac's IPv4 addresses on the local network, Wi-Fi (en0) first.
    static func lanAddresses() -> [(interface: String, address: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard !["utun", "awdl", "llw", "gif", "stf", "anpi"].contains(where: name.hasPrefix) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((name, text))
        }
        func rank(_ name: String) -> Int { name == "en0" ? 0 : name.hasPrefix("en") ? 1 : 2 }
        return found.sorted { rank($0.interface) < rank($1.interface) }
    }

    /// The link to give people, e.g. `http://192.168.1.5:52144/k3J9xQ2m7A8b/`. Nil when the Mac isn't on a network.
    var shareURL: URL? {
        guard port != 0, let address = Self.lanAddresses().first?.address else { return nil }
        return URL(string: "http://\(address):\(port)/\(token)/")
    }

    /// A QR code for `string`, sharp at any size (draw with `.interpolation(.none)`).
    static func qrCode(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// A short device name from a browser's user agent, e.g. "iPhone" or "Windows PC".
    static func deviceName(userAgent: String) -> String {
        let agent = userAgent.lowercased()
        if agent.contains("iphone") { return "iPhone" }
        if agent.contains("ipad") { return "iPad" }
        if agent.contains("android") { return agent.contains("mobile") ? "Android phone" : "Android tablet" }
        if agent.contains("windows") { return "Windows PC" }
        if agent.contains("cros") { return "Chromebook" }
        if agent.contains("macintosh") || agent.contains("mac os") { return "Mac" }
        if agent.contains("linux") { return "Linux computer" }
        return "Browser"
    }
}

/// Resumes a continuation exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
