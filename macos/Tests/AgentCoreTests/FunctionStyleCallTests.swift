import XCTest
@testable import AgentCore

final class FunctionStyleCallTests: XCTestCase {
    private let names: Set<String> = ["click", "move_mouse", "run_shell", "press_key", "type_text", "open_app", "scroll"]
    private func call(_ text: String) -> ToolCall? { ToolCallRecovery.extract(from: text, toolNames: names, schemas: []) }

    func testAPositionalClickBecomesTheClick() {
        let c = call("click(215, 204)")
        XCTAssertEqual(c?.name, "click")
        XCTAssertEqual(c?.arguments["x"]?.asInt, 215); XCTAssertEqual(c?.arguments["y"]?.asInt, 204)
    }

    func testNamedArgumentsStringsAndWrappers() {
        XCTAssertEqual(call("click(x=215, y=204)")?.arguments["y"]?.asInt, 204)
        XCTAssertEqual(call("`move_mouse(10, 20)`")?.name, "move_mouse")
        XCTAssertEqual(call("```\nclick(1, 2)\n```")?.arguments["x"]?.asInt, 1)
        XCTAssertEqual(call("run_shell(\"ls -la /workspace\")")?.arguments["command"]?.asString, "ls -la /workspace")
        XCTAssertEqual(call("press_key('ctrl+l')")?.arguments["key"]?.asString, "ctrl+l")
        XCTAssertEqual(call("type_text(\"a, b (c)\")")?.arguments["text"]?.asString, "a, b (c)", "commas and brackets inside quotes stay")
        XCTAssertEqual(call("open_app(\"browser\", \"http://x/y\")")?.arguments["url"]?.asString, "http://x/y")
        XCTAssertEqual(call("scroll(direction=\"down\", amount=3)")?.arguments["amount"]?.asInt, 3)
    }

    func testOnlyAWholeReplyThatIsOneKnownCallCounts() {
        XCTAssertNil(call("I'll click(215, 204) on the Reports tab."), "a sentence that mentions a call")
        XCTAssertNil(call("delete_everything(1)"), "not a tool")
        XCTAssertNil(call("click(1, 2) and then click(3, 4)"))
        XCTAssertNil(call("click(1, 2, 3, 4, 5)"), "more values than the tool has parameters")
        XCTAssertNil(call("click"))
    }

    func testExistingFormatsStillWin() {
        XCTAssertEqual(call("{\"name\": \"click\", \"arguments\": {\"x\": 5, \"y\": 6}}")?.arguments["x"]?.asInt, 5)
    }
}
