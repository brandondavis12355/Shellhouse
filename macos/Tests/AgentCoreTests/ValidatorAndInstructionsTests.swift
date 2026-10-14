import XCTest
@testable import AgentCore

/// A manager owner that only coordinates hands checking to a validator; bots can change bots' instructions,
/// but only with the user's OK.
final class ValidatorAndInstructionsTests: XCTestCase {
    private func goal() -> GroupGoal {
        var g = GroupGoal(title: "web UI", ownerBotID: "smith", steps: [.init(text: "Tai Lung: build the server", assigneeName: "Tai Lung")])
        g.validatorName = "Bugbot"
        return g
    }

    func testValidatorNotOwnerAcceptsSubmissions() {
        var g = goal()
        let id = g.steps[0].id
        XCTAssertTrue(g.validates("bugbot", isOwner: false))
        XCTAssertFalse(g.validates("Mr. Smith", isOwner: true), "the owner hands validation off")
        guard case .submitted = g.updateStep(id: id, status: .done, evidence: "curl localhost:5000/api/state -> 200 OK",
                                             assigneeName: nil, turnHadToolCalls: true, byOwner: false) else { return XCTFail("member submits") }
        XCTAssertNil(g.ownerReviewWork(), "the owner isn't asked to check it")
        XCTAssertTrue(g.validatorReviewWork()?.contains("step 1") == true)
        guard case .progress = g.updateStep(id: id, status: .done, evidence: "re-ran curl: /api/state -> 200 with board JSON",
                                            assigneeName: nil, turnHadToolCalls: true, byOwner: g.validates("Bugbot", isOwner: false)) else {
            return XCTFail("the validator marks it done")
        }
        XCTAssertTrue(g.promptBlock(ownerName: "Mr. Smith").contains("validated by: Bugbot"))
    }

    func testWithoutValidatorOwnerStillValidates() {
        var g = goal(); g.validatorName = nil
        XCTAssertTrue(g.validates("Mr. Smith", isOwner: true))
        XCTAssertNil(g.validatorReviewWork())
    }

    func testOldSavedGoalLoadsWithoutValidator() throws {
        var g = goal(); g.validatorName = nil
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
        json.removeValue(forKey: "validatorName")
        let decoded = try JSONDecoder().decode(GroupGoal.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.validatorName)
    }

    func testChangingInstructionsAlwaysAsksEvenInYolo() async {
        var config = GuardrailConfig(); config.yolo = true
        let asked = Asked()
        let gate = ToolGate(sandboxID: "t", sandbox: NullBox(), permissions: RunShellPermissions(), config: config, limits: RunLimits(),
                            audit: nil, inbox: nil, initialTaint: [], friendSafeTools: [],
                            requestApproval: { _ in asked.mark(); return .deny }, onEvent: { _ in })
        let call = ToolCall(name: "set_bot_instructions", arguments: ["bot": AnyCodable("Bugbot"), "text": AnyCodable("You review every PR.")])
        if case .run = await gate.evaluate(call) { XCTFail("a declined change must not run") }
        XCTAssertTrue(asked.value, "the user was asked")
        let read = ToolCall(name: "get_bot_instructions", arguments: [:])
        guard case .run(_, let askedHuman) = await gate.evaluate(read) else { return XCTFail("reading runs") }
        XCTAssertFalse(askedHuman)
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        func mark() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
    private final class NullBox: SandboxProvider, @unchecked Sendable {
        let name = "null"
        func exec(_ sandboxID: String, command: String, timeout: TimeInterval, env: [String: String]?) async throws -> ExecResult { ExecResult(exitCode: 0, stdout: "", stderr: "") }
        func create(taskID: String, persistent: Bool) async throws -> SandboxHandle { SandboxHandle(id: taskID, provider: name, persistent: persistent) }
        func start(_ sandboxID: String) async throws -> SandboxHandle { SandboxHandle(id: sandboxID, provider: name, persistent: true) }
        func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data { Data() }
        func writeFile(_ sandboxID: String, path: String, contents: Data) async throws {}
        func pause(_ sandboxID: String) async throws {}
        func resume(_ sandboxID: String) async throws {}
        func destroy(_ sandboxID: String) async throws {}
        func health(_ sandboxID: String) async -> Bool { true }
        func reconcile() async throws -> [SandboxHandle] { [] }
        func listSandboxes() async throws -> [SandboxHandle] { [] }
    }
}
