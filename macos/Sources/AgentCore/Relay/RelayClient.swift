import Foundation
import Security

// MARK: - Models (mirror group-relay's JSON)

public struct RelayFriend: Codable, Sendable, Equatable, Identifiable {
    public let userId: String
    public let displayName: String
    public var id: String { userId }
}

public struct RelayFriendList: Codable, Sendable, Equatable {
    public let friends: [RelayFriend]
    public let incoming: [RelayFriend]
    public let outgoing: [RelayFriend]
}

public struct RelayGroupSummary: Codable, Sendable, Equatable, Identifiable {
    public let groupId: String
    public let name: String
    public let ownerId: String
    public var id: String { groupId }
}

public struct RelayGroupDetail: Codable, Sendable, Equatable {
    public let groupId: String
    public let name: String
    public let ownerId: String
    public let members: [RelayFriend]
}

public struct RelayMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case human, bot, system }
    public let seq: Int
    public let kind: Kind
    public let speakerUserId: String?
    public let speakerName: String
    public let text: String
    public let ts: Double
    public var id: Int { seq }
}

public struct RelayMessagePage: Codable, Sendable, Equatable {
    public let messages: [RelayMessage]
    public let latestSeq: Int
}

public struct RelayInviteRedemption: Codable, Sendable, Equatable {
    public let status: String
    public let friend: RelayFriend
}

public enum RelayError: LocalizedError, Sendable, Equatable {
    case http(status: Int, detail: String)
    case transport(String)
    case invalidConfig(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let detail): return "Relay error \(status): \(detail)"
        case .transport(let message): return "Couldn't reach the relay: \(message)"
        case .invalidConfig(let message): return "Relay settings problem: \(message)"
        case .decoding(let message): return "Unexpected relay response: \(message)"
        }
    }

    /// The relay told us we're no longer allowed here (removed from the group,
    /// blocked, deleted, or this identity is unknown) — retrying won't help.
    /// A 401 for anything else (clock skew, a replayed nonce) is transient.
    public var isPermanent: Bool {
        guard case .http(let status, let detail) = self else { return false }
        if status == 401 { return detail.localizedCaseInsensitiveContains("unknown user") }
        return status == 403 || status == 404
    }

    /// The relay rejected THIS payload (bad/oversized message) — retrying the
    /// same message can never succeed, so a queue should skip it, not loop.
    public var isRejectedPayload: Bool {
        guard case .http(let status, _) = self else { return false }
        return status == 400 || status == 413 || status == 422
    }
}

// MARK: - Config

public struct RelayConfig: Sendable, Equatable {
    public var baseURL: URL
    /// SHA-256 fingerprint of the relay's certificate (as printed by
    /// `gen-cert.sh`). Required for https: the relay uses a self-signed
    /// certificate, so the pin IS the trust decision.
    public var pinnedFingerprint: String?
    public var registrationToken: String?
    /// Development/testing only: permit plain http to a loopback address.
    public var allowInsecureLoopback: Bool

    public init(baseURL: URL, pinnedFingerprint: String? = nil, registrationToken: String? = nil, allowInsecureLoopback: Bool = false) {
        self.baseURL = baseURL
        self.pinnedFingerprint = pinnedFingerprint
        self.registrationToken = registrationToken
        self.allowInsecureLoopback = allowInsecureLoopback
    }

    func validate() throws {
        guard let host = baseURL.host else { throw RelayError.invalidConfig("the relay address has no host") }
        switch baseURL.scheme {
        case "https":
            guard let pin = pinnedFingerprint, RelayCertificatePin.normalize(pin).count == 64 else {
                throw RelayError.invalidConfig("a valid certificate fingerprint (SHA-256) is required for https")
            }
        case "http":
            let loopback = ["127.0.0.1", "localhost", "::1"].contains(host)
            guard allowInsecureLoopback, loopback else {
                throw RelayError.invalidConfig("plain http is only allowed to a loopback address in development")
            }
        default:
            throw RelayError.invalidConfig("the relay address must be https")
        }
    }
}

/// Accepts the server's certificate only if its SHA-256 fingerprint equals the
/// pin (fail closed). Replaces normal CA validation, which can't work for a
/// self-signed certificate.
final class RelayPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinned: String?
    init(pinned: String?) { self.pinned = pinned }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let pinned,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        if RelayCertificatePin.matches(der: der, pinned: pinned) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Client

public actor RelayClient {
    public nonisolated let config: RelayConfig
    public nonisolated let identity: RelayIdentity
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(config: RelayConfig, identity: RelayIdentity) throws {
        try config.validate()
        self.config = config
        self.identity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(
            configuration: configuration,
            delegate: RelayPinningDelegate(pinned: config.baseURL.scheme == "https" ? config.pinnedFingerprint : nil),
            delegateQueue: nil
        )
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    deinit { session.invalidateAndCancel() }   // the session retains its pinning delegate

    // MARK: Transport

    private struct OK: Decodable { let ok: Bool? }

    private func send<T: Decodable>(
        _ method: String, _ path: String, query: [(String, String)] = [], body: (any Encodable)? = nil,
        timeout: TimeInterval = 20, extraHeaders: [String: String] = [:]
    ) async throws -> T {
        var components = URLComponents()
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        let pathWithQuery = components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        guard let url = URL(string: config.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + pathWithQuery) else {
            throw RelayError.invalidConfig("bad URL")
        }
        let bodyData = try body.map { try encoder.encode($0) } ?? Data()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if !bodyData.isEmpty {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let signed = try RelayRequestSigner.headers(for: identity, method: method, pathWithQuery: pathWithQuery, body: bodyData)
        for (key, value) in signed.merging(extraHeaders, uniquingKeysWith: { $1 }) { request.setValue(value, forHTTPHeaderField: key) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw RelayError.http(status: http.statusCode, detail: detail ?? "request failed")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RelayError.decoding("\(error)")
        }
    }

    // MARK: Identity

    private struct RegisterBody: Encodable { let userId: String; let displayName: String; let publicKey: String }
    public struct Registered: Decodable, Sendable { public let userId: String; public let displayName: String }

    /// Creates (or renames) this installation's identity on the relay.
    @discardableResult
    public func register(displayName: String) async throws -> Registered {
        var headers: [String: String] = [:]
        if let token = config.registrationToken, !token.isEmpty { headers["X-Registration-Token"] = token }
        return try await send(
            "POST", "/v1/register",
            body: RegisterBody(userId: identity.userID, displayName: displayName, publicKey: identity.publicKeyBase64),
            extraHeaders: headers
        )
    }

    public func me() async throws -> Registered { try await send("GET", "/v1/me") }

    // MARK: Friends

    private struct InviteResponse: Decodable { let code: String }
    private struct CodeBody: Encodable { let code: String }

    /// A one-time invite code (valid 24 h) to hand to a friend.
    public func createInvite() async throws -> String {
        let response: InviteResponse = try await send("POST", "/v1/invites")
        return response.code
    }

    public func redeemInvite(code: String) async throws -> RelayInviteRedemption {
        try await send("POST", "/v1/invites/redeem", body: CodeBody(code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public func friends() async throws -> RelayFriendList { try await send("GET", "/v1/friends") }
    public func acceptFriend(_ userID: String) async throws { let _: OK = try await send("POST", "/v1/friends/\(userID)/accept") }
    public func declineFriend(_ userID: String) async throws { let _: OK = try await send("POST", "/v1/friends/\(userID)/decline") }
    public func removeFriend(_ userID: String) async throws { let _: OK = try await send("DELETE", "/v1/friends/\(userID)") }
    public func block(_ userID: String) async throws { let _: OK = try await send("POST", "/v1/blocks/\(userID)") }

    // MARK: Groups

    private struct NameBody: Encodable { let name: String }
    private struct MemberBody: Encodable { let userId: String }

    public func createGroup(name: String) async throws -> RelayGroupSummary { try await send("POST", "/v1/groups", body: NameBody(name: name)) }
    public func groups() async throws -> [RelayGroupSummary] {
        struct Wrapper: Decodable { let groups: [RelayGroupSummary] }
        let wrapper: Wrapper = try await send("GET", "/v1/groups")
        return wrapper.groups
    }
    public func group(_ groupID: String) async throws -> RelayGroupDetail { try await send("GET", "/v1/groups/\(groupID)") }
    public func addMember(_ userID: String, to groupID: String) async throws {
        let _: OK = try await send("POST", "/v1/groups/\(groupID)/members", body: MemberBody(userId: userID))
    }
    public func removeMember(_ userID: String, from groupID: String) async throws {
        let _: OK = try await send("DELETE", "/v1/groups/\(groupID)/members/\(userID)")
    }
    public func deleteGroup(_ groupID: String) async throws { let _: OK = try await send("DELETE", "/v1/groups/\(groupID)") }

    // MARK: Messages

    private struct PostBody: Encodable {
        let text: String
        let kind: String
        let speakerName: String?
        let clientMsgId: String?
    }
    public struct Posted: Decodable, Sendable { public let seq: Int; public let duplicate: Bool }

    /// Posts as yourself (`human`). Pass a stable `clientMsgID` so a retry
    /// after a timeout can't double-post.
    @discardableResult
    public func postMessage(_ text: String, to groupID: String, clientMsgID: String = UUID().uuidString) async throws -> Posted {
        try await send("POST", "/v1/groups/\(groupID)/messages", body: PostBody(text: text, kind: "human", speakerName: nil, clientMsgId: clientMsgID))
    }

    /// Group OWNER only: mirror a bot's reply (or a system notice) to the relay.
    @discardableResult
    public func postMirrored(_ text: String, kind: RelayMessage.Kind, speakerName: String, to groupID: String, clientMsgID: String = UUID().uuidString) async throws -> Posted {
        try await send(
            "POST", "/v1/groups/\(groupID)/messages",
            body: PostBody(text: text, kind: kind.rawValue, speakerName: speakerName, clientMsgId: clientMsgID)
        )
    }

    /// Messages with `seq > after`. With `wait > 0` the relay holds the request
    /// open (up to 30 s) until something arrives.
    public func messages(in groupID: String, after: Int, limit: Int = 100, wait: Int = 0) async throws -> RelayMessagePage {
        try await send(
            "GET", "/v1/groups/\(groupID)/messages",
            query: [("after", String(after)), ("limit", String(limit)), ("wait", String(wait))],
            timeout: TimeInterval(wait + 15)
        )
    }
}

// MARK: - Live stream

/// Keeps a group's messages flowing: long-polls the relay, hands each new
/// batch to `onMessages`, and reconnects with exponential backoff on network
/// trouble. It gives up (calling `onEnded`) only when the relay says this
/// user is no longer allowed in the group (removed, blocked, deleted).
public final class RelayMessageStream: @unchecked Sendable {
    private let client: RelayClient
    private let groupID: String
    private let onMessages: @Sendable ([RelayMessage]) async -> Void
    private let onEnded: @Sendable (RelayError) async -> Void
    private let onConnectionChange: @Sendable (Bool) async -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cursor: Int
    private let pollSeconds: Int
    private let maxBackoff: TimeInterval

    public init(
        client: RelayClient, groupID: String, after: Int, pollSeconds: Int = 25, maxBackoff: TimeInterval = 30,
        onMessages: @escaping @Sendable ([RelayMessage]) async -> Void,
        onEnded: @escaping @Sendable (RelayError) async -> Void = { _ in },
        onConnectionChange: @escaping @Sendable (Bool) async -> Void = { _ in }
    ) {
        self.client = client
        self.groupID = groupID
        self.cursor = after
        self.pollSeconds = pollSeconds
        self.maxBackoff = maxBackoff
        self.onMessages = onMessages
        self.onEnded = onEnded
        self.onConnectionChange = onConnectionChange
    }

    /// The last delivered `seq` — persist this to resume without duplicates.
    public var lastSeq: Int { lock.lock(); defer { lock.unlock() }; return cursor }

    private func advanceCursor(to seq: Int) {
        lock.lock(); defer { lock.unlock() }
        cursor = max(cursor, seq)
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    private func run() async {
        var backoff: TimeInterval = 1
        var connected = true
        while !Task.isCancelled {
            do {
                let page = try await client.messages(in: groupID, after: lastSeq, wait: pollSeconds)
                if !connected { connected = true; await onConnectionChange(true) }
                backoff = 1
                if !page.messages.isEmpty {
                    advanceCursor(to: page.latestSeq)
                    await onMessages(page.messages)
                }
            } catch let error as RelayError where error.isPermanent {
                await onEnded(error)
                return
            } catch {
                if Task.isCancelled { return }
                if connected { connected = false; await onConnectionChange(false) }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }
}
