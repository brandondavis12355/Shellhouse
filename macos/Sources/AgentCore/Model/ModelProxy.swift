import Foundation
import Network
import Security

/// Token-gated local OpenAI-compatible reverse proxy (see docs/SMOLAGENTS.md
/// "Model access", docs/GUARDRAILS.md L0 "Model proxy").
///
/// A sandbox container reaches this (via `SSHTunnel` reverse forward) with a
/// per-run bearer token and never sees real provider credentials; the upstream
/// key comes from `Upstream.apiKey` and is added here.
///
/// Guarantees: loopback-only listener; only `POST /v1/chat/completions` and
/// `GET /v1/models` exist (everything else is 404 — no Ollama admin routes);
/// model pinned to the token's `allowedModel`; request/token budgets and expiry
/// per token; client-supplied Authorization is never forwarded. It never logs
/// or stores bodies, tokens or keys, and error text never contains them.
public final class ModelProxy: @unchecked Sendable {

    public struct Upstream: Sendable {
        /// Root of the OpenAI-compatible API, including `/v1`.
        public var apiRoot: URL
        /// Called per request; nil = no upstream auth (local Ollama).
        public var apiKey: @Sendable () async -> String?

        public init(apiRoot: URL, apiKey: @escaping @Sendable () async -> String? = { nil }) {
            self.apiRoot = apiRoot
            self.apiKey = apiKey
        }

        /// Local Ollama; its OpenAI-compatible API lives under `/v1`.
        public static let ollama = Upstream(apiRoot: URL(string: "http://127.0.0.1:11434/v1")!)
    }

    public struct Limits: Sendable {
        public var maxBodyBytes = 8 * 1024 * 1024
        public var maxHeaderBytes = 16 * 1024
        public var maxCompletionTokensPerRequest = 8192
        public var maxResponseBytes = 32 * 1024 * 1024
        public var maxConnections = 32
        /// Connections that have not authenticated yet are capped separately so
        /// idle sockets can't starve real requests.
        public var maxUnauthenticatedConnections = 12
        public var headerTimeout: TimeInterval = 3
        public var bodyTimeout: TimeInterval = 30
        public var upstreamTimeout: TimeInterval = 300
        public init() {}
    }

    /// Counters for UI. Contains no secrets.
    public struct Status: Sendable, Equatable {
        public var isListening: Bool
        public var port: UInt16?
        public var activeTokens: Int
        public var activeConnections: Int
        public var totalRequests: Int
        public var rejectedRequests: Int
    }

    public struct TokenUsage: Sendable, Equatable {
        public var allowedModel: String
        public var requests: Int
        public var maxRequests: Int
        public var totalTokens: Int
        public var maxTotalTokens: Int
        public var expiresAt: Date
    }

    // MARK: State

    private struct Grant {
        var allowedModel: String
        var maxRequests: Int
        var maxTotalTokens: Int
        var expires: Date
        var requests = 0
        var tokens = 0
    }

    private final class ConnRecord {
        var task: Task<Void, Never>?
        var tokenKey: String?
    }

    private let upstream: Upstream
    private let limits: Limits
    private let session: URLSession
    private let queue = DispatchQueue(label: "ModelProxy.network")
    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private var connections: [UUID: ConnRecord] = [:]
    private var listener: NWListener?
    private var startTask: Task<UInt16, Error>?
    private var boundPort: UInt16?
    private var totalRequests = 0
    private var rejected = 0

    public init(upstream: Upstream = .ollama, limits: Limits = Limits()) {
        self.upstream = upstream
        self.limits = limits
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = limits.upstreamTimeout
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: Tokens

    /// Random 256-bit token, base64url (no padding).
    @discardableResult
    public func issueToken(allowedModel: String, maxRequests: Int, maxTotalTokens: Int, ttl: TimeInterval) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        withLock {
            grants[token] = Grant(allowedModel: allowedModel, maxRequests: maxRequests,
                                  maxTotalTokens: maxTotalTokens, expires: Date().addingTimeInterval(ttl))
        }
        return token
    }

    /// Revokes the token and aborts its in-flight requests.
    public func revoke(_ token: String) {
        let victims: [Task<Void, Never>] = withLock {
            grants.removeValue(forKey: token)
            return connections.values.filter { $0.tokenKey == token }.compactMap(\.task)
        }
        victims.forEach { $0.cancel() }
    }

    public func revokeAll() {
        let victims: [Task<Void, Never>] = withLock {
            grants.removeAll()
            return connections.values.filter { $0.tokenKey != nil }.compactMap(\.task)
        }
        victims.forEach { $0.cancel() }
    }

    public func usage(for token: String) -> TokenUsage? {
        withLock {
            guard let key = matchKey(token), let grant = grants[key] else { return nil }
            return TokenUsage(allowedModel: grant.allowedModel, requests: grant.requests, maxRequests: grant.maxRequests,
                              totalTokens: grant.tokens, maxTotalTokens: grant.maxTotalTokens, expiresAt: grant.expires)
        }
    }

    public var status: Status {
        withLock {
            Status(isListening: listener != nil, port: boundPort, activeTokens: grants.count,
                   activeConnections: connections.count, totalRequests: totalRequests, rejectedRequests: rejected)
        }
    }

    public var port: UInt16? { withLock { boundPort } }

    // MARK: Lifecycle

    /// Starts listening on 127.0.0.1. `port` 0 picks an ephemeral port.
    /// Returns the actual port.
    @discardableResult
    public func start(port requested: UInt16 = 0) async throws -> UInt16 {
        // Serialized: concurrent callers share one in-flight start.
        let task: Task<UInt16, Error> = withLock {
            if let existing = startTask { return existing }
            let created = Task<UInt16, Error> { [self] in try await self.startOnce(port: requested) }
            startTask = created
            return created
        }
        defer { withLock { startTask = nil } }
        return try await task.value
    }

    private func startOnce(port requested: UInt16) async throws -> UInt16 {
        if let existing = port { return existing }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested)!)
        let newListener = try NWListener(using: params)
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let actual: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce()
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.take() { cont.resume(returning: newListener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.take() { cont.resume(throwing: error) }
                    newListener.cancel()
                    self?.listenerEnded(newListener)
                case .cancelled:
                    if once.take() { cont.resume(throwing: CancellationError()) }
                    self?.listenerEnded(newListener)
                default: break
                }
            }
            newListener.start(queue: queue)
        }
        withLock { listener = newListener; boundPort = actual }
        return actual
    }

    /// A listener that fails or is cancelled after it came up must not leave
    /// the proxy looking alive (so the next `start` really restarts it).
    private func listenerEnded(_ ended: NWListener) {
        withLock {
            if listener === ended { listener = nil; boundPort = nil }
        }
    }

    /// Stops listening and aborts all in-flight connections. Tokens survive
    /// (call `revokeAll()` to drop them).
    public func stop() {
        let (old, tasks): (NWListener?, [Task<Void, Never>]) = withLock {
            let l = listener
            listener = nil
            boundPort = nil
            return (l, connections.values.compactMap(\.task))
        }
        old?.cancel()
        tasks.forEach { $0.cancel() }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let record = ConnRecord()
        let admitted: Bool = withLock {
            guard connections.count < limits.maxConnections else { return false }
            guard connections.values.filter({ $0.tokenKey == nil }).count < limits.maxUnauthenticatedConnections else { return false }
            connections[id] = record
            return true
        }
        guard admitted else { connection.cancel(); return }
        // Created under the lock so a concurrent revoke/stop sees the task.
        withLock {
            record.task = Task { [weak self] in
                guard let self else { connection.cancel(); return }
                await withTaskCancellationHandler {
                    await self.serve(connection, id: id, record: record)
                } onCancel: {
                    connection.cancel()
                }
                self.withLock { _ = self.connections.removeValue(forKey: id) }
            }
        }
    }

    private func serve(_ conn: NWConnection, id: UUID, record: ConnRecord) async {
        conn.start(queue: queue)
        defer { conn.cancel() }
        do {
            let response = try await handle(conn, record: record)
            if let response { try await Self.send(conn, response, final: true) }
        } catch let failure as HTTPFailure {
            withLock { rejected += 1 }
            try? await Self.send(conn, Self.errorResponse(failure), final: true)
            // Let a client that is still uploading finish (or time out) so it
            // reads our status instead of seeing a connection reset.
            await drain(conn)
        } catch {
            // Client went away / timeout / cancelled: nothing to answer.
        }
    }

    private func drain(_ conn: NWConnection) async {
        let guardTimer = watchdog(conn, after: 1.5)
        defer { guardTimer.cancel() }
        var drained = 0
        while drained < 16 * 1024 * 1024 {
            guard let (chunk, complete) = try? await Self.receive(conn) else { return }
            drained += chunk.count
            if complete { return }
        }
    }

    // MARK: Request handling

    /// Returns a fully buffered response to send, or nil when the response was
    /// already streamed to the connection.
    private func handle(_ conn: NWConnection, record: ConnRecord) async throws -> Data? {
        // --- head (slowloris guard: whole head within headerTimeout)
        var buffer = Data()
        var headEnd: Range<Data.Index>?
        let headWatchdog = watchdog(conn, after: limits.headerTimeout)
        defer { headWatchdog.cancel() }
        let terminator = Data("\r\n\r\n".utf8)
        while headEnd == nil {
            let (chunk, complete) = try await Self.receive(conn)
            buffer.append(chunk)
            headEnd = buffer.range(of: terminator)
            if headEnd == nil, buffer.count > limits.maxHeaderBytes { throw HTTPFailure(status: 431, message: "headers too large") }
            if headEnd == nil, complete { throw HTTPFailure(status: 400, message: "incomplete request") }
        }
        headWatchdog.cancel()
        guard let end = headEnd, end.lowerBound <= limits.maxHeaderBytes else { throw HTTPFailure(status: 431, message: "headers too large") }
        let head = try HTTPHead.parse(buffer.subdata(in: 0..<end.lowerBound))
        var body = buffer.subdata(in: end.upperBound..<buffer.count)

        // --- route allowlist (nothing else exists)
        let isChat = head.method == "POST" && head.path == "/v1/chat/completions"
        let isModels = head.method == "GET" && head.path == "/v1/models"
        guard isChat || isModels else { throw HTTPFailure(status: 404, message: "not found") }

        // --- auth
        let key = try authenticate(head)
        withLock { record.tokenKey = key }

        // --- framing
        if head.headers["transfer-encoding"] != nil { throw HTTPFailure(status: 501, message: "chunked request bodies are not supported") }
        var contentLength = 0
        if let raw = head.headers["content-length"] {
            guard !raw.isEmpty, raw.count <= 10, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let value = Int(raw) else {
                throw HTTPFailure(status: 400, message: "bad content-length")
            }
            contentLength = value
        } else if isChat {
            throw HTTPFailure(status: 411, message: "content-length required")
        }
        guard contentLength <= limits.maxBodyBytes else { throw HTTPFailure(status: 413, message: "request body too large") }

        if isModels {
            let grant = withLock { grants[key] }
            let model = grant?.allowedModel ?? ""
            let payload: [String: Any] = ["object": "list",
                                          "data": [["id": model, "object": "model", "created": 0, "owned_by": "proxy"]]]
            return try Self.jsonResponse(200, payload)
        }

        // --- body
        if head.headers["expect"]?.lowercased() == "100-continue", body.count < contentLength {
            try await Self.send(conn, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), final: false)
        }
        let bodyWatchdog = watchdog(conn, after: limits.bodyTimeout)
        defer { bodyWatchdog.cancel() }
        while body.count < contentLength {
            let (chunk, complete) = try await Self.receive(conn)
            body.append(chunk)
            if body.count < contentLength, complete { throw HTTPFailure(status: 400, message: "incomplete body") }
        }
        bodyWatchdog.cancel()
        if body.count > contentLength { body = body.prefix(contentLength) }

        return try await forwardChat(conn, key: key, body: body)
    }

    private func authenticate(_ head: HTTPRequestHead) throws -> String {
        let unauthorized = HTTPFailure(status: 401, message: "invalid or missing token", extraHeaders: ["WWW-Authenticate": "Bearer"])
        guard let header = head.headers["authorization"] else { throw unauthorized }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { throw unauthorized }
        let presented = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let key: String? = withLock {
            guard let key = matchKey(presented), let grant = grants[key] else { return nil }
            if grant.expires <= Date() { grants.removeValue(forKey: key); return nil }
            return key
        }
        guard let key else { throw unauthorized }
        return key
    }

    /// Constant-time scan over every token (no early exit). Caller holds the lock.
    private func matchKey(_ presented: String) -> String? {
        var found: String?
        for candidate in grants.keys where constantTimeEquals(candidate, presented) { found = candidate }
        return found
    }

    private func forwardChat(_ conn: NWConnection, key: String, body: Data) async throws -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw HTTPFailure(status: 400, message: "body must be a JSON object")
        }
        guard let allowed = withLock({ grants[key]?.allowedModel }) else {
            throw HTTPFailure(status: 401, message: "invalid or missing token")
        }
        guard let model = object["model"] as? String else { throw HTTPFailure(status: 400, message: "model is required") }
        guard constantTimeEquals(model, allowed) else { throw HTTPFailure(status: 403, message: "model not permitted for this token") }
        if let n = object["n"] as? Int, n > 1 { throw HTTPFailure(status: 400, message: "n > 1 is not permitted") }
        let streaming = (object["stream"] as? Bool) ?? false
        // Only standard chat-completion fields go upstream: no Ollama-specific
        // options (keep_alive, options.*) and no remote image fetches.
        object = object.filter { Self.allowedFields.contains($0.key) }
        if Self.containsRemoteImage(object["messages"]) {
            throw HTTPFailure(status: 400, message: "only inline (data:) images are permitted")
        }

        // Budget reservation (counts the request, enforces both limits).
        let estimatedPrompt = (body.count + 3) / 4
        let cap: Int = try withLock {
            guard var grant = grants[key], grant.expires > Date() else { throw HTTPFailure(status: 401, message: "invalid or missing token") }
            guard grant.requests < grant.maxRequests else { throw HTTPFailure(status: 429, message: "request budget exhausted") }
            let remaining = grant.maxTotalTokens - grant.tokens - estimatedPrompt
            guard remaining > 0 else { throw HTTPFailure(status: 429, message: "token budget exhausted") }
            let cap = min(limits.maxCompletionTokensPerRequest, remaining)
            grant.requests += 1
            // Reserve the worst case up front so parallel requests can't each
            // pass the budget check and collectively overspend it.
            grant.tokens += estimatedPrompt + cap
            grants[key] = grant
            totalRequests += 1
            return cap
        }
        let reserved = estimatedPrompt + cap

        var charged = estimatedPrompt  // replaced by upstream usage when present
        var usageReported = false
        defer {
            let delta = charged - reserved   // refund the unused part of the reservation
            withLock { if var grant = grants[key] { grant.tokens = max(0, grant.tokens + delta); grants[key] = grant } }
        }

        var hadLimit = false
        for field in ["max_tokens", "max_completion_tokens"] {
            if let value = object[field] as? Int {
                object[field] = min(max(value, 1), cap)
                hadLimit = true
            } else if object[field] != nil {
                object[field] = cap
                hadLimit = true
            }
        }
        if !hadLimit { object["max_tokens"] = cap }
        if streaming {
            var options = (object["stream_options"] as? [String: Any]) ?? [:]
            options["include_usage"] = true
            object["stream_options"] = options
        }
        let outBody = try JSONSerialization.data(withJSONObject: object)

        // Only these headers ever reach upstream; client headers are dropped.
        var request = URLRequest(url: upstream.apiRoot.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = outBody
        request.timeoutInterval = limits.upstreamTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let secret = await upstream.apiKey(), !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HTTPFailure(status: 502, message: "upstream unavailable")
        }
        let upstreamStatus = (response as? HTTPURLResponse)?.statusCode ?? 502
        guard (200..<300).contains(upstreamStatus) else {
            let passthrough = [400, 404, 422, 429].contains(upstreamStatus) ? upstreamStatus : 502
            throw HTTPFailure(status: passthrough, message: "upstream returned HTTP \(upstreamStatus)")
        }

        if !streaming {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limits.maxResponseBytes { throw HTTPFailure(status: 502, message: "upstream response too large") }
            }
            if let tokens = Self.totalTokens(in: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) {
                charged = tokens
            } else {
                charged += (data.count + 3) / 4
            }
            return Self.response(200, contentType: "application/json", body: data)
        }

        // Streaming SSE pass-through (chunked to the client), line at a time.
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
            + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        try await Self.send(conn, Data(head.utf8), final: false)
        var line = Data()
        var estimatedCompletion = 0
        var sent = 0
        func flush(_ piece: Data) async throws {
            var chunk = Data(String(piece.count, radix: 16).utf8)
            chunk.append(contentsOf: [13, 10])
            chunk.append(piece)
            chunk.append(contentsOf: [13, 10])
            try await Self.send(conn, chunk, final: false)
        }
        func inspect(_ raw: Data) {
            guard raw.starts(with: Data("data:".utf8)) else { return }
            let payload = raw.dropFirst(5)
            guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
            if let tokens = Self.totalTokens(in: json) { charged = tokens; usageReported = true; return }
            if let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
                for field in ["content", "reasoning", "reasoning_content"] {
                    if let text = delta[field] as? String { estimatedCompletion += text.utf8.count }
                }
            }
        }
        for try await byte in bytes {
            line.append(byte)
            if byte == 10 {
                inspect(line)
                sent += line.count
                if sent > limits.maxResponseBytes { throw CancellationError() }
                try await flush(line)
                line.removeAll(keepingCapacity: true)
            } else if line.count > 1_048_576 {
                throw CancellationError()  // absurdly long line: abort the stream
            }
        }
        if !line.isEmpty { try await flush(line) }
        if !usageReported { charged += (estimatedCompletion + 3) / 4 }
        try await Self.send(conn, Data("0\r\n\r\n".utf8), final: true)
        return nil
    }

    static let allowedFields: Set<String> = [
        "model", "messages", "stream", "stream_options", "temperature", "top_p", "max_tokens", "max_completion_tokens",
        "stop", "tools", "tool_choice", "parallel_tool_calls", "seed", "frequency_penalty", "presence_penalty",
        "response_format", "user",
    ]

    static func containsRemoteImage(_ messages: Any?) -> Bool {
        guard let list = messages as? [[String: Any]] else { return false }
        for message in list {
            guard let parts = message["content"] as? [[String: Any]] else { continue }
            for part in parts where (part["type"] as? String) == "image_url" {
                let url = ((part["image_url"] as? [String: Any])?["url"] as? String) ?? (part["image_url"] as? String) ?? ""
                if !url.lowercased().hasPrefix("data:") { return true }
            }
        }
        return false
    }

    private static func totalTokens(in json: [String: Any]?) -> Int? {
        guard let usage = json?["usage"] as? [String: Any] else { return nil }
        if let total = usage["total_tokens"] as? Int { return max(0, total) }
        let prompt = usage["prompt_tokens"] as? Int ?? 0
        let completion = usage["completion_tokens"] as? Int ?? 0
        return (prompt + completion) > 0 ? prompt + completion : nil
    }

    // MARK: Responses

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }

    private static func response(_ status: Int, contentType: String, body: Data, extra: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func jsonResponse(_ status: Int, _ object: [String: Any]) throws -> Data {
        response(status, contentType: "application/json", body: try JSONSerialization.data(withJSONObject: object))
    }

    private static func errorResponse(_ failure: HTTPFailure) -> Data {
        let payload: [String: Any] = ["error": ["message": failure.message, "type": "proxy_error"]]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return response(failure.status, contentType: "application/json", body: body, extra: failure.extraHeaders)
    }

    // MARK: NWConnection helpers

    private func watchdog(_ conn: NWConnection, after seconds: TimeInterval) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { conn.cancel() }
        }
    }

    private static func receive(_ conn: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), complete))
            }
        }
    }

    private static func send(_ conn: NWConnection, _ data: Data, final: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                      completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Never follow upstream redirects (would re-send the upstream key elsewhere).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
