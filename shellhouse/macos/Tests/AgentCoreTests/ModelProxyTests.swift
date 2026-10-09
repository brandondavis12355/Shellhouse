import XCTest
import Network
@testable import AgentCore

/// Tiny HTTP server on loopback standing in for Ollama / a remote provider.
final class FakeUpstream: @unchecked Sendable {
    struct Seen { var path: String; var headers: [String: String]; var body: Data }
    private let queue = DispatchQueue(label: "fake-upstream")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _seen: [Seen] = []
    var status = 200
    var responseBody = Data(#"{"id":"x","choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}"#.utf8)
    var sseLines: [String] = []
    var port: UInt16 = 0
    var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return _seen }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        port = try await withCheckedThrowingContinuation { cont in
            var done = false
            l.stateUpdateHandler = { state in
                guard !done else { return }
                if case .ready = state { done = true; cont.resume(returning: l.port!.rawValue) }
                if case .failed(let e) = state { done = true; cont.resume(throwing: e) }
            }
            l.start(queue: queue)
        }
        listener = l
    }
    func stop() { listener?.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buf = Data()
        func step() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, err in
                if let data { buf.append(data) }
                guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { if err == nil { step() }; return }
                let head = String(decoding: buf[0..<r.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for l in head.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let need = Int(headers["content-length"] ?? "0") ?? 0
                let body = buf[r.upperBound...]
                if body.count < need { if err == nil { step() }; return }
                lock.lock(); _seen.append(Seen(path: String(head[0].split(separator: " ")[1]), headers: headers, body: Data(body))); lock.unlock()
                respond(c, streaming: (try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])?["stream"] as? Bool == true)
            }
        }
        step()
    }

    private func respond(_ c: NWConnection, streaming: Bool) {
        if streaming && status == 200 {
            c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            for line in sseLines {
                let payload = line + "\n\n"
                c.send(content: Data("\(String(payload.utf8.count, radix: 16))\r\n\(payload)\r\n".utf8), completion: .contentProcessed { _ in })
            }
            c.send(content: Data("0\r\n\r\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        } else {
            var out = Data("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(responseBody)
            c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
    }
}

final class ModelProxyTests: XCTestCase {
    private var fake: FakeUpstream!
    private var proxy: ModelProxy!
    private var port: UInt16 = 0
    private let secretKey = "sk-UPSTREAM-SECRET-123"
    private var urlSession: URLSession!

    override func setUp() async throws {
        fake = FakeUpstream()
        try await fake.start()
        let key = secretKey
        proxy = ModelProxy(upstream: .init(apiRoot: URL(string: "http://127.0.0.1:\(fake.port)/v1")!, apiKey: { key }))
        port = try await proxy.start()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        urlSession = URLSession(configuration: cfg)
    }

    override func tearDown() async throws {
        proxy.stop()
        fake.stop()
    }

    // MARK: helpers

    private func call(_ method: String, _ path: String, token: String?, body: String? = nil,
                      headers: [String: String] = [:]) async throws -> (Int, String, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = Data(body.utf8); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await urlSession.data(for: req)
        let http = resp as! HTTPURLResponse
        return (http.statusCode, String(decoding: data, as: UTF8.self), http)
    }

    private func chat(_ token: String?, model: String = "m1", extra: String = "", headers: [String: String] = [:]) async throws -> (Int, String, HTTPURLResponse) {
        try await call("POST", "/v1/chat/completions", token: token,
                       body: #"{"model":"\#(model)","messages":[{"role":"user","content":"hello"}]\#(extra)}"#, headers: headers)
    }

    private func token(model: String = "m1", requests: Int = 10, tokens: Int = 10_000, ttl: TimeInterval = 60) -> String {
        proxy.issueToken(allowedModel: model, maxRequests: requests, maxTotalTokens: tokens, ttl: ttl)
    }

    private func raw(_ bytes: String, readFor seconds: TimeInterval = 2) async -> String {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.start(queue: .global())
        conn.send(content: Data(bytes.utf8), completion: .contentProcessed { _ in })
        var out = Data()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (d, done): (Data?, Bool) = await withCheckedContinuation { c in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, e in c.resume(returning: (d, done || e != nil)) }
            }
            if let d { out.append(d) }
            if done { break }
        }
        conn.cancel()
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: tests

    func testTokenIsBase64URL256Bit() {
        let t = token()
        XCTAssertEqual(t.count, 43)
        XCTAssertNil(t.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
        XCTAssertNotEqual(t, token())
    }

    func testBoundToLoopbackAndReportsPort() {
        XCTAssertNotEqual(port, 0)
        XCTAssertEqual(proxy.status.port, port)
        XCTAssertTrue(proxy.status.isListening)
    }

    func testAuthFailures() async throws {
        var r = try await chat(nil); XCTAssertEqual(r.0, 401)
        XCTAssertEqual(r.2.value(forHTTPHeaderField: "WWW-Authenticate"), "Bearer")
        r = try await chat("wrong-token"); XCTAssertEqual(r.0, 401)
        r = try await chat(token(ttl: -1)); XCTAssertEqual(r.0, 401)
        let revoked = token(); proxy.revoke(revoked)
        r = try await chat(revoked); XCTAssertEqual(r.0, 401)
        let all = token(); proxy.revokeAll()
        r = try await chat(all); XCTAssertEqual(r.0, 401)
        r = try await call("POST", "/v1/chat/completions", token: nil, headers: ["Authorization": "Basic abc"]); XCTAssertEqual(r.0, 401)
        XCTAssertTrue(fake.seen.isEmpty, "nothing may reach upstream without a valid token")
    }

    func testRouteAllowlist() async throws {
        let t = token()
        for (m, p) in [("GET", "/api/tags"), ("POST", "/api/pull"), ("DELETE", "/api/delete"), ("POST", "/api/create"),
                       ("POST", "/api/push"), ("POST", "/api/copy"), ("GET", "/v1/models/x"), ("POST", "/v1/embeddings"),
                       ("GET", "/v1/chat/completions"), ("POST", "/v1/models"), ("GET", "/")] {
            let r = try await call(m, p, token: t, body: m == "POST" ? "{}" : nil)
            XCTAssertEqual(r.0, 404, "\(m) \(p)")
        }
        XCTAssertTrue(fake.seen.isEmpty)
        let models = try await call("GET", "/v1/models", token: t)
        XCTAssertEqual(models.0, 200)
        XCTAssertTrue(models.1.contains("\"m1\""))
        let unauth = try await call("GET", "/v1/models", token: nil)
        XCTAssertEqual(unauth.0, 401)
    }

    func testModelMismatchAndBadBodies() async throws {
        let t = token()
        var r = try await chat(t, model: "other"); XCTAssertEqual(r.0, 403)
        r = try await call("POST", "/v1/chat/completions", token: t, body: #"{"messages":[]}"#); XCTAssertEqual(r.0, 400)
        r = try await call("POST", "/v1/chat/completions", token: t, body: "not json"); XCTAssertEqual(r.0, 400)
        r = try await chat(t, extra: #","n":3"#); XCTAssertEqual(r.0, 400)
        XCTAssertTrue(fake.seen.isEmpty)
        XCTAssertEqual(proxy.usage(for: t)?.requests, 0, "rejected requests are not charged")
    }

    func testBodySizeCapAndFraming() async throws {
        let t = token(ttl: 600)
        // Declared size is rejected before any body is read.
        let r = await raw("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\nContent-Length: 9000000\r\n\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 413"), r)
        let exact = String(repeating: "a", count: 8 * 1024 * 1024 + 1)
        let r2 = (try? await call("POST", "/v1/chat/completions", token: t, body: exact))?.0
        XCTAssertTrue(r2 == 413 || r2 == nil)  // nil: server closed while client still uploading
        let chunked = await raw("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        XCTAssertTrue(chunked.hasPrefix("HTTP/1.1 501"), chunked)
        let noLen = await raw("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(noLen.hasPrefix("HTTP/1.1 411"), noLen)
        let hugeHeader = await raw("POST /v1/chat/completions HTTP/1.1\r\nX: " + String(repeating: "a", count: 40_000) + "\r\n\r\n")
        XCTAssertTrue(hugeHeader.hasPrefix("HTTP/1.1 431"), hugeHeader)
        let garbage = await raw("NOT HTTP\r\n\r\n")
        XCTAssertTrue(garbage.hasPrefix("HTTP/1.1 400"), garbage)
        XCTAssertTrue(fake.seen.isEmpty)
    }

    func testSlowlorisHeaderTimeout() async throws {
        var limits = ModelProxy.Limits(); limits.headerTimeout = 0.5
        let p = ModelProxy(upstream: .ollama, limits: limits)
        let pt = try await p.start()
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: pt)!, using: .tcp)
        conn.start(queue: .global())
        conn.send(content: Data("POST /v1/chat/completions HTT".utf8), completion: .contentProcessed { _ in })
        let closed: Bool = await withCheckedContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 10) { _, _, done, e in c.resume(returning: done || e != nil) }
        }
        XCTAssertTrue(closed)
        conn.cancel(); p.stop()
    }

    func testRequestAndTokenLimits() async throws {
        let t = token(requests: 2)
        var r = try await chat(t); XCTAssertEqual(r.0, 200)
        r = try await chat(t); XCTAssertEqual(r.0, 200)
        r = try await chat(t); XCTAssertEqual(r.0, 429)
        XCTAssertEqual(proxy.usage(for: t)?.requests, 2)
        XCTAssertEqual(proxy.usage(for: t)?.totalTokens, 14, "uses upstream usage.total_tokens")

        let small = token(tokens: 20)           // each call reports 7 tokens
        var codes: [Int] = []
        for _ in 0..<5 { codes.append(try await chat(small).0) }
        XCTAssertTrue(codes.contains(429), "\(codes)")
        XCTAssertLessThanOrEqual(proxy.usage(for: small)!.totalTokens, 20 + 7)
    }

    func testMaxTokensClampedAndNonStreamingPassThrough() async throws {
        let t = token()
        let r = try await chat(t, extra: #","max_tokens":999999,"temperature":0.2"#)
        XCTAssertEqual(r.0, 200)
        XCTAssertTrue(r.1.contains("\"hi\""))
        let sent = try XCTUnwrap(fake.seen.last)
        XCTAssertEqual(sent.path, "/v1/chat/completions")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(obj["max_tokens"] as? Int, 8192)
        XCTAssertEqual(obj["temperature"] as? Double, 0.2)
        XCTAssertEqual(obj["model"] as? String, "m1")
        // No client max_tokens: one is imposed.
        _ = try await chat(t)
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(with: fake.seen.last!.body) as? [String: Any])
        XCTAssertNotNil(obj2["max_tokens"])
    }

    func testClientHeadersStrippedAndUpstreamAuthAdded() async throws {
        let t = token()
        let r = try await chat(t, headers: ["X-Api-Key": "client-key", "Cookie": "a=b", "OpenAI-Organization": "org-evil", "Proxy-Authorization": "x"])
        XCTAssertEqual(r.0, 200)
        let h = try XCTUnwrap(fake.seen.last).headers
        XCTAssertEqual(h["authorization"], "Bearer \(secretKey)")
        XCTAssertNil(h["x-api-key"]); XCTAssertNil(h["cookie"]); XCTAssertNil(h["openai-organization"]); XCTAssertNil(h["proxy-authorization"])
        XCTAssertFalse(h.values.contains { $0.contains(t) }, "client token must not reach upstream")
        XCTAssertFalse(r.1.contains(secretKey))
    }

    func testStreamingPassThrough() async throws {
        fake.sseLines = [
            #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#,
            "data: [DONE]",
        ]
        let t = token()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(#"{"model":"m1","stream":true,"messages":[]}"#.utf8)
        let (bytes, resp) = try await urlSession.bytes(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        var lines: [String] = []
        for try await line in bytes.lines where !line.isEmpty { lines.append(line) }
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.last, "data: [DONE]")
        XCTAssertTrue(lines[0].contains("Hel"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: fake.seen.last!.body) as? [String: Any])
        XCTAssertEqual((obj["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(proxy.usage(for: t)?.totalTokens, 7)
    }

    func testUpstreamErrorsDoNotLeakSecrets() async throws {
        fake.status = 401
        fake.responseBody = Data("bad key \(secretKey)".utf8)
        let t = token()
        let r = try await chat(t)
        XCTAssertEqual(r.0, 502)
        XCTAssertFalse(r.1.contains(secretKey))
        XCTAssertFalse(r.1.contains(t))
        // Unreachable upstream
        fake.stop()
        let p = ModelProxy(upstream: .init(apiRoot: URL(string: "http://127.0.0.1:1/v1")!, apiKey: { "sk-zzz" }))
        let pp = try await p.start()
        let tt = p.issueToken(allowedModel: "m1", maxRequests: 1, maxTotalTokens: 1000, ttl: 60)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(pp)/v1/chat/completions")!)
        req.httpMethod = "POST"; req.setValue("Bearer \(tt)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(#"{"model":"m1","messages":[]}"#.utf8)
        let (d, resp) = try await urlSession.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 502)
        let text = String(decoding: d, as: UTF8.self)
        XCTAssertFalse(text.contains("sk-zzz")); XCTAssertFalse(text.contains(tt))
        p.stop()
    }

    func testStopClosesListenerAndDropsConnections() async throws {
        proxy.stop()
        XCTAssertFalse(proxy.status.isListening)
        let out = await raw("GET /v1/models HTTP/1.1\r\n\r\n", readFor: 1)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: review regressions

    func testParallelRequestsCannotCollectivelyOverspendTheTokenBudget() async throws {
        let t = token(tokens: 6_000, ttl: 600)
        fake.responseBody = Data(#"{"choices":[],"usage":{"total_tokens":5}}"#.utf8)
        var statuses: [Int] = []
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 { group.addTask { try await self.chat(t).0 } }
            for try await code in group { statuses.append(code) }
        }
        let used = proxy.usage(for: t)?.totalTokens ?? Int.max
        XCTAssertLessThanOrEqual(used, 6_000, "reservations must keep the grant within its budget")
        XCTAssertTrue(statuses.contains(429) || statuses.allSatisfy { $0 == 200 })
        // After completion the reservation is refunded down to what was really used.
        XCTAssertLessThan(used, 2_000)
    }

    func testOnlyStandardChatFieldsReachUpstream() async throws {
        let t = token(ttl: 600)
        _ = try await chat(t, extra: #","keep_alive":-1,"options":{"num_ctx":999999},"format":"json","think":true,"temperature":0.2"#)
        let body = try XCTUnwrap(fake.seen.last?.body)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(sent["keep_alive"]); XCTAssertNil(sent["options"]); XCTAssertNil(sent["format"]); XCTAssertNil(sent["think"])
        XCTAssertNotNil(sent["temperature"]); XCTAssertNotNil(sent["messages"])
    }

    func testRemoteImageUrlsAreRefusedButInlineImagesPass() async throws {
        let t = token(ttl: 600)
        let remote = #"{"model":"m1","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"http://169.254.169.254/x"}}]}]}"#
        let (code, _, _) = try await call("POST", "/v1/chat/completions", token: t, body: remote)
        XCTAssertEqual(code, 400)
        let inline = #"{"model":"m1","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}"#
        let (ok, _, _) = try await call("POST", "/v1/chat/completions", token: t, body: inline)
        XCTAssertEqual(ok, 200)
    }

    func testConcurrentStartsShareOneListener() async throws {
        let other = ModelProxy(upstream: .ollama)
        defer { other.stop() }
        async let a = other.start()
        async let b = other.start()
        let (p1, p2) = try await (a, b)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(other.port, p1)
    }

    func testStoppedProxyReportsNotListeningAndCanRestart() async throws {
        let other = ModelProxy(upstream: .ollama)
        _ = try await other.start()
        other.stop()
        XCTAssertNil(other.port)
        let again = try await other.start()
        XCTAssertNotNil(other.port)
        XCTAssertEqual(other.port, again)
        other.stop()
    }
}
