import XCTest
@testable import AgentCore

final class FallbackBackendTests: XCTestCase {
    private final class Fake: ModelBackend, @unchecked Sendable {
        let name: String
        private let lock = NSLock()
        private var _calls: [String?] = []
        var failure: Error?
        init(_ name: String, failure: Error? = nil) { self.name = name; self.failure = failure }
        var calls: [String?] { lock.lock(); defer { lock.unlock() }; return _calls }
        func supportsVision(model: String?) async -> Bool { false }
        func availableModels() async throws -> [String] { [] }
        func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
            lock.lock(); _calls.append(model); let failure = failure; lock.unlock()
            if let failure { throw failure }
            return ModelReply(message: ChatMessage(role: .assistant, content: name), usage: nil)
        }
    }
    private final class Switches: @unchecked Sendable {
        private let lock = NSLock(); private var list: [Bool] = []
        func add(_ b: Bool) { lock.lock(); list.append(b); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return list }
    }
    private let down = URLError(.cannotConnectToHost)

    func testUnreachableMainModelFallsBackAndStaysThereForAWhile() async throws {
        let main = Fake("main", failure: down), backup = Fake("backup"), state = FallbackState(), switches = Switches()
        let backend = FallbackBackend(primary: main, fallback: backup, fallbackModel: "small", state: state, retryDelays: [0, 0]) { to, _ in switches.add(to) }
        let reply = try await backend.chat(messages: [], tools: [], model: "big", temperature: 0)
        XCTAssertEqual(reply.message.content, "backup")
        XCTAssertEqual(main.calls.count, 3, "a few tries first")
        XCTAssertEqual(backup.calls, ["small"], "the fallback gets its own model name")
        _ = try await backend.chat(messages: [], tools: [], model: "big", temperature: 0)
        XCTAssertEqual(main.calls.count, 3, "the next request goes straight to the fallback")
        XCTAssertEqual(switches.all, [true])
    }

    func testBackOnMainAfterCooldown() async throws {
        let main = Fake("main", failure: down), backup = Fake("backup"), state = FallbackState(cooldown: 0), switches = Switches()
        let backend = FallbackBackend(primary: main, fallback: backup, fallbackModel: "small", state: state, retryDelays: []) { to, _ in switches.add(to) }
        _ = try await backend.chat(messages: [], tools: [], model: "big", temperature: 0)
        main.failure = nil
        let reply = try await backend.chat(messages: [], tools: [], model: "big", temperature: 0)
        XCTAssertEqual(reply.message.content, "main")
        XCTAssertEqual(switches.all, [true, false])
    }

    func testServerAnsweredErrorsAreNotHidden() async {
        let main = Fake("main", failure: ModelError.requestFailed(status: 401, detail: "bad key")), backup = Fake("backup")
        let backend = FallbackBackend(primary: main, fallback: backup, fallbackModel: "small", state: FallbackState(), retryDelays: [0])
        do { _ = try await backend.chat(messages: [], tools: [], model: "big", temperature: 0); XCTFail("should throw") } catch {}
        XCTAssertTrue(backup.calls.isEmpty)
        XCTAssertTrue(FallbackBackend.isUnreachable(ModelError.requestFailed(status: 503, detail: "")))
        XCTAssertTrue(FallbackBackend.isUnreachable(ModelError.requestFailed(status: 429, detail: "")))
        XCTAssertFalse(FallbackBackend.isUnreachable(ModelError.requestFailed(status: 400, detail: "")))
    }

    func testInnermostSeesThroughWrappers() {
        let local = OllamaBackend(defaultModel: "m")
        let scheduled = ScheduledBackend(local, bot: "b") { 0 }
        let wrapped = FallbackBackend(primary: scheduled, fallback: Fake("r"), fallbackModel: "x", state: FallbackState())
        XCTAssertTrue(wrapped.innermost is OllamaBackend)
    }
}
