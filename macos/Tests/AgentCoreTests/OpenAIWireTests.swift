import XCTest
@testable import AgentCore

/// Strict OpenAI-compatible servers (Gemini's among them) need each tool result tied to the call it answers.
final class OpenAIWireTests: XCTestCase {
    private func json(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(OpenAICompatibleBackend.wireMessages(messages))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testToolCallsAndResultsArePairedById() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "list files"),
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(name: "list_files", arguments: ["path": AnyCodable(".")], id: "call_abc"),
                ToolCall(name: "read_file", arguments: ["path": AnyCodable("a.py")]),
            ]),
            ChatMessage(role: .tool, content: #"{"entries":["a.py"]}"#, toolName: "list_files"),
            ChatMessage(role: .tool, content: #"{"content":"x"}"#, toolName: "read_file"),
            ChatMessage(role: .assistant, content: "Done."),
        ]
        let wire = try json(messages)
        XCTAssertEqual(wire.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool", "assistant"])
        let calls = try XCTUnwrap(wire[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]["id"] as? String, "call_abc")
        let synthesized = try XCTUnwrap(calls[1]["id"] as? String)
        XCTAssertEqual(wire[3]["tool_call_id"] as? String, "call_abc")
        XCTAssertEqual(wire[4]["tool_call_id"] as? String, synthesized)
        XCTAssertNil(wire[2]["content"], "no empty text alongside the calls")
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["arguments"] as? String, #"{"path":"."}"#)
    }

    func testOrphanResultsAndUnansweredCallsStayValid() throws {
        let wire = try json([
            ChatMessage(role: .user, content: "(summary of earlier work)"),
            ChatMessage(role: .tool, content: "old output", toolName: "run_shell"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "run_shell", arguments: [:], id: "c1")]),
            ChatMessage(role: .user, content: "stop"),
        ])
        XCTAssertEqual(wire.map { $0["role"] as? String }, ["user", "user", "assistant", "tool", "user"])
        XCTAssertEqual(wire[3]["tool_call_id"] as? String, "c1", "an unanswered call gets a placeholder result")
    }
}

final class AppSecretTests: XCTestCase {
    func testAppOwnCredentialsAreReserved() {
        for name in ["SANDBOX_MANAGER_TOKEN", "RELAY_REGISTRATION_TOKEN", "RELAY_IDENTITY_KEY_V1", "FAST_MODEL_API_KEY", "REMOTE_API_KEY_BOT_1A2B"] {
            XCTAssertTrue(SecretStore.isAppInternal(name), name)
        }
        XCTAssertFalse(SecretStore.isAppInternal("GITHUB_TOKEN"))
        XCTAssertFalse(SecretStore.isAppInternal("SITE_PASSWORD"))
    }
}
