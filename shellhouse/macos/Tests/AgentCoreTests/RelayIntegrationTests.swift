import Foundation
import XCTest
@testable import AgentCore

/// End-to-end: the Swift client talking to the REAL Python relay
/// (group-relay/app). Skipped unless RELAY_TEST_PYTHON points at a Python with
/// the relay's requirements installed, e.g.
///   RELAY_TEST_PYTHON=/path/to/venv/bin/python swift test --filter RelayIntegration
final class RelayIntegrationTests: XCTestCase {
    // MARK: Harness

    private final class RelayProcess {
        let port: Int
        let dbPath: String
        let useTLS: Bool
        let certDir: String?
        private var process: Process?

        init(port: Int, dbPath: String, certDir: String? = nil) {
            self.port = port
            self.dbPath = dbPath
            self.certDir = certDir
            self.useTLS = certDir != nil
        }

        static func freePort() -> Int {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(sock) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(sock, $0, &len) } }
            return Int(UInt16(bigEndian: addr.sin_port))
        }

        func start(python: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            var args = ["-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", String(port), "--log-level", "warning"]
            if let certDir { args += ["--ssl-certfile", "\(certDir)/cert.pem", "--ssl-keyfile", "\(certDir)/key.pem"] }
            process.arguments = args
            let appDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("group-relay/app")
            process.currentDirectoryURL = appDir
            var env = ProcessInfo.processInfo.environment
            env["RELAY_DB"] = dbPath
            env["RELAY_MAX_HUMANS"] = "20"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            self.process = process
            try waitUntilListening()
        }

        /// uvicorn's graceful shutdown waits for open connections (a held
        /// long-poll, a keep-alive), which can take many seconds — give it a
        /// moment, then kill it so a test can never hang on cleanup.
        func stop() {
            guard let process else { return }
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            self.process = nil
        }

        private func waitUntilListening() throws {
            for _ in 0..<100 {
                let sock = socket(AF_INET, SOCK_STREAM, 0)
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                addr.sin_port = UInt16(port).bigEndian
                let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                Darwin.close(sock)
                if result == 0 { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw XCTSkip("relay did not start")
        }
    }

    private func python() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["RELAY_TEST_PYTHON"] else {
            throw XCTSkip("set RELAY_TEST_PYTHON to run relay integration tests")
        }
        return path
    }

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "relay-it-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func client(_ port: Int, _ identity: RelayIdentity = RelayIdentity()) throws -> RelayClient {
        try RelayClient(
            config: .init(baseURL: URL(string: "http://127.0.0.1:\(port)")!, allowInsecureLoopback: true),
            identity: identity
        )
    }

    private actor Collector {
        var messages: [RelayMessage] = []
        var connectionEvents: [Bool] = []
        var ended: RelayError?
        func add(_ new: [RelayMessage]) { messages.append(contentsOf: new) }
        func connection(_ up: Bool) { connectionEvents.append(up) }
        func end(_ error: RelayError) { ended = error }
        func texts() -> [String] { messages.map(\.text) }
    }

    private func eventually(timeout: TimeInterval = 20, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // MARK: Tests

    func testFullFlowAgainstRealRelay() async throws {
        let python = try python()
        let server = RelayProcess(port: RelayProcess.freePort(), dbPath: tempDir() + "/relay.db")
        try server.start(python: python)
        defer { server.stop() }

        let alice = try client(server.port), bob = try client(server.port)
        try await alice.register(displayName: "Alice")
        try await bob.register(displayName: "Bob")
        let me = try await alice.me()
        XCTAssertEqual(me.displayName, "Alice")

        let code = try await alice.createInvite()
        let redemption = try await bob.redeemInvite(code: code)
        XCTAssertEqual(redemption.status, "pending")
        var list = try await alice.friends()
        XCTAssertEqual(list.incoming.map(\.displayName), ["Bob"])
        try await alice.acceptFriend(list.incoming[0].userId)
        list = try await bob.friends()
        XCTAssertEqual(list.friends.map(\.displayName), ["Alice"])

        let group = try await alice.createGroup(name: "Team")
        try await alice.addMember(bob.identity.userID, to: group.groupId)
        let detail = try await bob.group(group.groupId)
        XCTAssertEqual(Set(detail.members.map(\.displayName)), ["Alice", "Bob"])

        let first = try await bob.postMessage("hello from bob", to: group.groupId, clientMsgID: "c1")
        let retry = try await bob.postMessage("hello from bob", to: group.groupId, clientMsgID: "c1")
        XCTAssertTrue(retry.duplicate)
        XCTAssertEqual(first.seq, retry.seq)
        try await alice.postMirrored("I am a bot", kind: .bot, speakerName: "Helper", to: group.groupId)

        let page = try await bob.messages(in: group.groupId, after: 0)
        XCTAssertEqual(page.messages.map(\.text), ["hello from bob", "I am a bot"])
        XCTAssertEqual(page.messages[0].speakerName, "Bob")
        XCTAssertEqual(page.messages[1].kind, .bot)

        // A friend can never impersonate a bot or the system.
        do {
            try await bob.postMirrored("fake", kind: .system, speakerName: "System", to: group.groupId)
            XCTFail("member posted a system message")
        } catch let error as RelayError {
            XCTAssertEqual(error, .http(status: 403, detail: "only the group owner can post bot or system messages"))
        }

        // A stranger cannot read or probe the group.
        let eve = try client(server.port)
        try await eve.register(displayName: "Eve")
        do {
            _ = try await eve.messages(in: group.groupId, after: 0)
            XCTFail("non-member read messages")
        } catch let error as RelayError {
            XCTAssertTrue(error.isPermanent)
        }
    }

    func testLongPollReturnsWhenMessageArrives() async throws {
        let python = try python()
        let server = RelayProcess(port: RelayProcess.freePort(), dbPath: tempDir() + "/relay.db")
        try server.start(python: python)
        defer { server.stop() }
        let (alice, bob, groupID) = try await makeFriendsAndGroup(server.port)

        let started = Date()
        async let page = alice.messages(in: groupID, after: 0, wait: 15)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await bob.postMessage("late", to: groupID)
        let result = try await page
        XCTAssertEqual(result.messages.map(\.text), ["late"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testStreamDeliversInOrderReconnectsAndEndsWhenRemoved() async throws {
        let python = try python()
        let db = tempDir() + "/relay.db"
        let port = RelayProcess.freePort()
        var server = RelayProcess(port: port, dbPath: db)
        try server.start(python: python)
        defer { server.stop() }
        let (alice, bob, groupID) = try await makeFriendsAndGroup(port)

        let collector = Collector()
        let stream = RelayMessageStream(
            client: bob, groupID: groupID, after: 0, pollSeconds: 2, maxBackoff: 1,
            onMessages: { await collector.add($0) },
            onEnded: { await collector.end($0) },
            onConnectionChange: { await collector.connection($0) }
        )
        stream.start()
        defer { stream.stop() }

        try await alice.postMessage("one", to: groupID)
        try await alice.postMessage("two", to: groupID)
        let gotTwo = await eventually { await collector.texts() == ["one", "two"] }
        XCTAssertTrue(gotTwo, "messages delivered in order")
        XCTAssertGreaterThan(stream.lastSeq, 0)

        // Server goes away and comes back (same database): the stream must recover on its own.
        server.stop()
        let sawDown = await eventually { await collector.connectionEvents.contains(false) }
        XCTAssertTrue(sawDown, "stream reports the connection dropping")
        server = RelayProcess(port: port, dbPath: db)
        try server.start(python: python)
        try await alice.postMessage("three", to: groupID)
        let recovered = await eventually(timeout: 30) { await collector.texts() == ["one", "two", "three"] }
        XCTAssertTrue(recovered, "no loss and no duplicates across the outage")
        let eventsAfter = await collector.connectionEvents
        XCTAssertEqual(eventsAfter.last, true)

        // Removed from the group: the stream stops instead of retrying forever.
        try await alice.removeMember(bob.identity.userID, from: groupID)
        let ended = await eventually { await collector.ended != nil }
        XCTAssertTrue(ended)
        let endError = await collector.ended
        XCTAssertEqual(endError?.isPermanent, true)
    }

    /// Needs a relay serving TLS with a self-signed cert, reachable at
    /// RELAY_TEST_TLS_URL, whose SHA-256 fingerprint is RELAY_TEST_TLS_FINGERPRINT
    /// (as printed by gen-cert.sh). Not launched locally: macOS's system Python
    /// links LibreSSL 2.8, which can't serve modern TLS; run the relay container
    /// (e.g. on the Linux host, reached over an ssh -L forward) instead.
    func testCertificatePinningAcceptsOnlyTheRightCertificate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlText = env["RELAY_TEST_TLS_URL"], let url = URL(string: urlText),
              let fingerprint = env["RELAY_TEST_TLS_FINGERPRINT"] else {
            throw XCTSkip("set RELAY_TEST_TLS_URL and RELAY_TEST_TLS_FINGERPRINT to run the pinning test")
        }
        let good = try RelayClient(config: .init(baseURL: url, pinnedFingerprint: fingerprint), identity: RelayIdentity())
        let registered = try await good.register(displayName: "Pinned")
        XCTAssertEqual(registered.displayName, "Pinned")
        let me = try await good.me()
        XCTAssertEqual(me.userId, good.identity.userID)

        let wrongPin = String(repeating: "ab", count: 32)
        let bad = try RelayClient(config: .init(baseURL: url, pinnedFingerprint: wrongPin), identity: RelayIdentity())
        do {
            try await bad.register(displayName: "Should-not-connect")
            XCTFail("connected despite a wrong pin")
        } catch let error as RelayError {
            if case .transport = error {} else { XCTFail("expected a transport failure, got \(error)") }
        }
    }

    /// The friend's side: joins later, gets the full shared history in order,
    /// posts, leaves, and loses access.
    func testFriendJoinsLateSeesHistoryPostsAndLeaves() async throws {
        let python = try python()
        let server = RelayProcess(port: RelayProcess.freePort(), dbPath: tempDir() + "/relay.db")
        try server.start(python: python)
        defer { server.stop() }
        let alice = try client(server.port), bob = try client(server.port)
        try await alice.register(displayName: "Alice")
        try await bob.register(displayName: "Bob")
        let code = try await alice.createInvite()
        _ = try await bob.redeemInvite(code: code)
        try await alice.acceptFriend(bob.identity.userID)
        let group = try await alice.createGroup(name: "Team")

        try await alice.postMessage("hi from the owner", to: group.groupId)
        try await alice.postMirrored("bot reply", kind: .bot, speakerName: "Helper", to: group.groupId)
        try await alice.postMirrored("goal set", kind: .system, speakerName: "Goal", to: group.groupId)

        // Not a member yet: no access at all.
        do { _ = try await bob.messages(in: group.groupId, after: 0); XCTFail("read before being added") }
        catch let error as RelayError { XCTAssertTrue(error.isPermanent) }

        try await alice.addMember(bob.identity.userID, to: group.groupId)
        let joined = try await bob.groups()
        XCTAssertEqual(JoinedGroupFilter.joined(joined, myUserID: bob.identity.userID).map(\.name), ["Team"])
        let aliceGroups = try await alice.groups()
        XCTAssertTrue(JoinedGroupFilter.joined(aliceGroups, myUserID: alice.identity.userID).isEmpty)

        let collector = Collector()
        let stream = RelayMessageStream(client: bob, groupID: group.groupId, after: 0, pollSeconds: 2, maxBackoff: 1,
                                        onMessages: { await collector.add($0) })
        stream.start()
        defer { stream.stop() }
        let history = await eventually { await collector.texts() == ["hi from the owner", "bot reply", "goal set"] }
        XCTAssertTrue(history, "full shared history, in order, including bot and system kinds")
        let kinds = await collector.messages.map(\.kind)
        XCTAssertEqual(kinds, [.human, .bot, .system])

        try await bob.postMessage("hello from the friend", to: group.groupId)
        let echoed = await eventually { await collector.texts().last == "hello from the friend" }
        XCTAssertTrue(echoed, "own message comes back through the stream")
        let ownerView = try await alice.messages(in: group.groupId, after: 0).messages.last
        XCTAssertEqual(ownerView?.speakerUserId, bob.identity.userID)

        try await bob.removeMember(bob.identity.userID, from: group.groupId)
        do { _ = try await bob.messages(in: group.groupId, after: 0); XCTFail("still had access after leaving") }
        catch let error as RelayError { XCTAssertTrue(error.isPermanent) }
    }

    // MARK: Helpers

    private func makeFriendsAndGroup(_ port: Int) async throws -> (RelayClient, RelayClient, String) {
        let alice = try client(port), bob = try client(port)
        try await alice.register(displayName: "Alice")
        try await bob.register(displayName: "Bob")
        let code = try await alice.createInvite()
        _ = try await bob.redeemInvite(code: code)
        try await alice.acceptFriend(bob.identity.userID)
        let group = try await alice.createGroup(name: "Team")
        try await alice.addMember(bob.identity.userID, to: group.groupId)
        return (alice, bob, group.groupId)
    }
}
