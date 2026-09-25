import XCTest
@testable import AgentCore

/// The unit tests the Python build never got. Pure functions first: they are
/// cheap to test and nasty when wrong.
final class PolicyTests: XCTestCase {

    func testReadOnlyToolsAreAllowed() {
        XCTAssertEqual(Policy.evaluate(tool: "read_file"), .allow)
        XCTAssertEqual(Policy.evaluate(tool: "web_search"), .allow)
    }

    func testShellAlwaysRequiresApproval() {
        XCTAssertEqual(Policy.evaluate(tool: "run_shell"), .requireApproval)
    }

    /// The important default: an unrecognized tool must ask a human, not be
    /// assumed safe.
    func testUnknownToolRequiresApproval() {
        XCTAssertEqual(Policy.evaluate(tool: "definitely_not_a_tool"), .requireApproval)
    }

    func testDurableUserMemoryRequiresApproval() {
        XCTAssertEqual(Policy.evaluate(tool: "remember"), .requireApproval)
        XCTAssertEqual(Policy.evaluate(tool: "save_evidence"), .allow)
    }

    // MARK: - MCP

    func testMcpToolsRequireApprovalByDefault() {
        XCTAssertEqual(Policy.evaluate(tool: "mcp__github__create_issue"), .requireApproval)
    }

    func testTrustedMcpReadOnlyToolIsAllowed() {
        let decision = Policy.evaluate(
            tool: "mcp__internal__list_repos",
            mcpTrustedServers: ["internal"],
            mcpReadOnlyHint: { _ in true }
        )
        XCTAssertEqual(decision, .allow)
    }

    /// Trusting a server must not extend to its write operations.
    func testTrustedMcpWriteToolStillRequiresApproval() {
        let decision = Policy.evaluate(
            tool: "mcp__internal__delete_repo",
            mcpTrustedServers: ["internal"],
            mcpReadOnlyHint: { _ in false }
        )
        XCTAssertEqual(decision, .requireApproval)
    }

    func testMalformedMcpNameIsDenied() {
        XCTAssertEqual(Policy.evaluate(tool: "mcp__"), .deny)
    }
}

final class PathSafetyTests: XCTestCase {
    /// A stand-in provider, since safeRelativePath is a protocol extension.
    private struct Dummy: SandboxProvider {
        let name = "dummy"
        func create(taskID: String, persistent: Bool) async throws -> SandboxHandle {
            SandboxHandle(id: "d", provider: name, persistent: false)
        }
        func start(_ id: String) async throws -> SandboxHandle {
            SandboxHandle(id: "d", provider: name, persistent: false)
        }
        func exec(_ id: String, command: String, timeout: TimeInterval,
                  env: [String: String]?) async throws -> ExecResult {
            ExecResult(exitCode: 0, stdout: "", stderr: "")
        }
        func readFile(_ id: String, path: String, maxBytes: Int) async throws -> Data { Data() }
        func writeFile(_ id: String, path: String, contents: Data) async throws {}
        func pause(_ id: String) async throws {}
        func resume(_ id: String) async throws {}
        func destroy(_ id: String) async throws {}
        func health(_ id: String) async -> Bool { true }
        func reconcile() async throws -> [SandboxHandle] { [] }
        func listSandboxes() async throws -> [SandboxHandle] { [] }
    }

    func testNormalPathsPass() throws {
        let provider = Dummy()
        XCTAssertEqual(try provider.safeRelativePath("notes.md"), "notes.md")
        XCTAssertEqual(try provider.safeRelativePath("/notes.md"), "notes.md")
        XCTAssertEqual(try provider.safeRelativePath("sub/dir/f.txt"), "sub/dir/f.txt")
    }

    func testTraversalIsRejected() {
        let provider = Dummy()
        XCTAssertThrowsError(try provider.safeRelativePath("../../etc/passwd"))
        XCTAssertThrowsError(try provider.safeRelativePath("a/../../../etc/passwd"))
    }
}
