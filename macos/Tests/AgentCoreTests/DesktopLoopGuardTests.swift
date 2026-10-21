import XCTest
@testable import AgentCore

final class DesktopLoopGuardTests: XCTestCase {
    private func secret(_ name: String = "SITE_PASSWORD", window: String = "Sign in") -> ToolCall {
        ToolCall(name: "type_secret", arguments: ["name": AnyCodable(name), "window": AnyCodable(window)])
    }
    private func click(_ x: Int, _ y: Int) -> ToolCall { ToolCall(name: "click", arguments: ["x": AnyCodable(x), "y": AnyCodable(y)]) }
    private func key(_ k: String) -> ToolCall { ToolCall(name: "press_key", arguments: ["key": AnyCodable(k)]) }
    private func ran(_ raw: [String: Any] = ["ok": true]) -> ToolOutcome { ToolOutcome(kind: .executed(isObservation: false), raw: raw, shown: raw) }

    func testASecretIsTypedOncePerWindowUntilTheFieldIsCleared() {
        let g = RepeatedSecretGuard(); let ctx = RunContext()
        XCTAssertTrue(g.beforeTool(secret(), ctx).isEmpty)
        _ = g.afterTool(secret(), ran(), ctx)
        guard case .replaceResult(let json, let kind)? = g.beforeTool(secret(), ctx).first else { return XCTFail("second type was allowed") }
        XCTAssertEqual(kind, "repeated_secret"); XCTAssertTrue(json.contains("ctrl+a"))
        XCTAssertTrue(g.beforeTool(secret("SITE_USERNAME"), ctx).isEmpty, "another secret is fine")
        XCTAssertTrue(g.beforeTool(secret(window: "Other"), ctx).isEmpty, "another window is fine")
        _ = g.afterTool(key("ctrl+a"), ran(), ctx)
        XCTAssertTrue(g.beforeTool(secret(), ctx).isEmpty, "after the field is selected it may be typed again")
    }

    func testAFailedTypeDoesNotCount() {
        let g = RepeatedSecretGuard(); let ctx = RunContext()
        _ = g.afterTool(secret(), ran(["error": "no window matching that title"]), ctx)
        XCTAssertTrue(g.beforeTool(secret(), ctx).isEmpty)
    }

    func testSubmittingOrOpeningAnotherPageAllowsItAgain() {
        for reset in [key("Return"), ToolCall(name: "open_app", arguments: ["app": AnyCodable("browser")])] {
            let g = RepeatedSecretGuard(); let ctx = RunContext()
            _ = g.afterTool(secret(), ran(), ctx); _ = g.afterTool(reset, ran(), ctx)
            XCTAssertTrue(g.beforeTool(secret(), ctx).isEmpty, reset.name)
        }
    }

    func testClickingTheSameSpotIsNudgedAtThreeAndSixButMovingIsNot() {
        let g = NearRepeatClickGuard(); let ctx = RunContext()
        var nudges: [Int] = []
        for (i, spot) in [(168, 592), (168, 594), (165, 592), (165, 594), (165, 592), (168, 593)].enumerated() {
            if case .nudge(let n)? = g.afterTool(click(spot.0, spot.1), ran(), ctx).first { nudges.append(i + 1); XCTAssertEqual(n.kind, "near_repeat_click") }
        }
        XCTAssertEqual(nudges, [3, 6])
        let h = NearRepeatClickGuard()
        for spot in [(100, 100), (300, 200), (500, 400), (100, 100), (300, 200), (500, 400)] {
            XCTAssertTrue(h.afterTool(click(spot.0, spot.1), ran(), ctx).isEmpty)
        }
    }

    func testTypingOrAKeyResetsTheClickCount() {
        let g = NearRepeatClickGuard(); let ctx = RunContext()
        _ = g.afterTool(click(10, 10), ran(), ctx); _ = g.afterTool(click(10, 10), ran(), ctx)
        _ = g.afterTool(ToolCall(name: "type_text", arguments: ["text": AnyCodable("x")]), ran(), ctx)
        XCTAssertTrue(g.afterTool(click(10, 10), ran(), ctx).isEmpty)
        _ = g.afterTool(ToolCall(name: "screenshot", arguments: [:]), ran(), ctx)
        _ = g.afterTool(click(10, 10), ran(), ctx)
        XCTAssertFalse(g.afterTool(click(10, 10), ran(), ctx).isEmpty, "a screenshot does not reset it: that is the third close click")
    }

    func testNonSecretCredentialValuesSaySoAndAStoppedRequestIsNotAnError() {
        let r = CredentialRequest.result(saved: ["SITE_PASSWORD"], kept: [], missing: [], plain: ["SITE_USERNAME": "someone"], failed: [])
        XCTAssertTrue((r["values_note"] as? String)?.contains("type_text") == true)
        XCTAssertNil(CredentialRequest.result(saved: ["A"], kept: [], missing: [], plain: [:], failed: [])["values_note"])
    }

    private func call(_ name: String) -> ToolCall { ToolCall(name: name, arguments: ["x": AnyCodable(1), "y": AnyCodable(1), "text": AnyCodable("a"), "app": AnyCodable("browser")]) }

    func testNothingIsClickedOrTypedBeforeTheScreenHasBeenSeen() {
        let g = LookFirstGuard(); let ctx = RunContext()
        for name in ["click", "scroll", "type_text"] {
            guard case .replaceResult(let json, let kind)? = g.beforeTool(call(name), ctx).first else { return XCTFail("\(name) was allowed blind") }
            XCTAssertEqual(kind, "look_first"); XCTAssertTrue(json.contains("screenshot"))
        }
        XCTAssertTrue(g.beforeTool(call("press_key"), ctx).isEmpty, "a key press is not aimed at coordinates")
        XCTAssertTrue(g.beforeTool(call("screenshot"), ctx).isEmpty)
        XCTAssertTrue(g.beforeTool(call("run_shell"), ctx).isEmpty)
    }

    func testOneScreenshotOpensTheTurnAndAnActionResultCountsAsALook() {
        let g = LookFirstGuard(); let ctx = RunContext()
        _ = g.afterTool(call("screenshot"), ran(), ctx)
        XCTAssertTrue(g.beforeTool(call("click"), ctx).isEmpty)
        let h = LookFirstGuard()
        _ = h.afterTool(call("type_text"), ran(), ctx)
        XCTAssertTrue(h.beforeTool(call("click"), ctx).isEmpty, "type_text's own screenshot is a look")
    }

    func testAFailedLookDoesNotCountAndOpeningAnAppAsksForANewOne() {
        let g = LookFirstGuard(); let ctx = RunContext()
        _ = g.afterTool(call("screenshot"), ran(["error": "scrot failed"]), ctx)
        XCTAssertFalse(g.beforeTool(call("click"), ctx).isEmpty)
        _ = g.afterTool(call("screenshot"), ran(), ctx)
        XCTAssertTrue(g.beforeTool(call("click"), ctx).isEmpty)
        _ = g.afterTool(call("open_app"), ran(), ctx)
        XCTAssertFalse(g.beforeTool(call("click"), ctx).isEmpty, "the page changed: look again")
        g.reset(.turn)
        _ = g.afterTool(call("screenshot"), ran(), ctx); g.reset(.turn)
        XCTAssertFalse(g.beforeTool(call("click"), ctx).isEmpty, "a new turn starts without a look")
    }
}
