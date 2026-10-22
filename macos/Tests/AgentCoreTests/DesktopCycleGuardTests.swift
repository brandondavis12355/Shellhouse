import XCTest
@testable import AgentCore

final class DesktopCycleGuardTests: XCTestCase {
    private func ran(_ raw: [String: Any] = ["ok": true, "screenshot": "s.png", "screen_changed": true]) -> ToolOutcome {
        ToolOutcome(kind: .executed(isObservation: false), raw: raw, shown: raw)
    }
    private func ctx(saying text: String = "The login form is open, so I will click the username field.") -> RunContext {
        var c = RunContext(); c.messages = [ChatMessage(role: .assistant, content: text)]; return c
    }
    private func call(_ name: String) -> ToolCall { ToolCall(name: name, arguments: [:]) }
    private func nudgeKinds(_ actions: [GuardAction]) -> [String] { actions.compactMap { if case .nudge(let n) = $0 { return n.kind } else { return nil } } }

    func testAnActionBeforeTheFirstLookBecomesTheLookAndTheDecidePromptFollows() {
        let g = DesktopCycleGuard()
        guard case .rewrite(let replaced)? = g.beforeTool(call("click_text"), ctx()).first else { return XCTFail("acted blind") }
        XCTAssertEqual(replaced.name, "screenshot")
        let annotated = g.afterTool(replaced, ran(["ok": true]), ctx())
        guard case .annotate(let key, let note)? = annotated.first else { return XCTFail("no explanation") }
        XCTAssertEqual(key, "harness_note"); XCTAssertTrue(note.contains("click_text") && note.contains("not run"))
        XCTAssertEqual(nudgeKinds(g.afterTurn(ranTools: true, ctx())), ["desktop_decide"])
        XCTAssertTrue(nudgeKinds(g.afterTurn(ranTools: true, ctx())).isEmpty, "asked once per look")
    }

    func testAnActionNeedsAReasonOnceThenGoesThrough() {
        let g = DesktopCycleGuard()
        _ = g.afterTool(call("screenshot"), ran(["ok": true]), ctx())
        guard case .replaceResult(let json, let kind)? = g.beforeTool(call("click_text"), ctx(saying: "")).first else { return XCTFail("no reasoning asked for") }
        XCTAssertEqual(kind, "desktop_reason_first"); XCTAssertTrue(json.contains("why"))
        XCTAssertTrue(g.beforeTool(call("click_text"), ctx(saying: "")).isEmpty, "asked once, not forever")
        XCTAssertTrue(DesktopCycleGuard().beforeTool(call("screenshot"), ctx(saying: "")).isEmpty, "looking needs no reason")
    }

    func testOneActionPerReplyAndAVerifyPromptAfterIt() {
        let g = DesktopCycleGuard()
        _ = g.afterTool(call("screenshot"), ran(["ok": true]), ctx())
        XCTAssertTrue(g.beforeTool(call("click_text"), ctx()).isEmpty)
        _ = g.afterTool(call("click_text"), ran(), ctx())
        guard case .replaceResult(_, let kind)? = g.beforeTool(call("fill_field"), ctx()).first else { return XCTFail("two actions in one reply") }
        XCTAssertEqual(kind, "desktop_one_action")
        XCTAssertEqual(nudgeKinds(g.afterTurn(ranTools: true, ctx())), ["desktop_verify"])
        XCTAssertTrue(g.beforeTool(call("fill_field"), ctx()).isEmpty, "the next reply may act again")
    }

    func testThreeActionsThatChangedNothingEndTheWork() {
        let g = DesktopCycleGuard()
        _ = g.afterTool(call("screenshot"), ran(["ok": true]), ctx())
        var last: [String] = []
        for _ in 0..<3 {
            _ = g.afterTool(call("click"), ran(["ok": true, "screenshot": "s.png", "screen_changed": false]), ctx())
            last = nudgeKinds(g.afterTurn(ranTools: true, ctx()))
        }
        XCTAssertEqual(last, ["desktop_stop"])
    }

    func testAnActionWithNoScreenshotInItsResultSendsTheNextOneToLookFirst() {
        let g = DesktopCycleGuard()
        _ = g.afterTool(call("screenshot"), ran(["ok": true]), ctx())
        _ = g.afterTool(call("type_secret"), ran(["ok": true]), ctx()); _ = g.afterTurn(ranTools: true, ctx())
        guard case .rewrite(let r)? = g.beforeTool(call("press_key"), ctx()).first else { return XCTFail("did not look") }
        XCTAssertEqual(r.name, "screenshot")
    }

    func testNonDesktopWorkIsLeftAlone() {
        let g = DesktopCycleGuard()
        XCTAssertTrue(g.beforeTool(call("run_shell"), ctx(saying: "")).isEmpty)
        XCTAssertTrue(g.afterTurn(ranTools: true, ctx()).isEmpty)
    }
}
