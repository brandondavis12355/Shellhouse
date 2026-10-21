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
        for name in ["press_key", "click_text", "fill_field", "type_secret"] {
            XCTAssertFalse(g.beforeTool(call(name), ctx).isEmpty, "\(name) changes the page, so it needs a before-screenshot")
        }
        XCTAssertTrue(g.beforeTool(call("screenshot"), ctx).isEmpty)
        XCTAssertTrue(g.beforeTool(call("run_shell"), ctx).isEmpty)
    }

    private func at(_ name: String, _ x: Int, _ y: Int) -> ToolCall { ToolCall(name: name, arguments: ["x": AnyCodable(x), "y": AnyCodable(y)]) }

    func testAUsernameIsNeverMadeUp() {
        let g = KnownUsernameGuard(); var ctx = RunContext()
        func fill(_ label: String, _ text: String) -> ToolCall { ToolCall(name: "fill_field", arguments: ["label": AnyCodable(label), "text": AnyCodable(text)]) }
        XCTAssertFalse(g.beforeTool(fill("Username", "admin"), ctx).isEmpty)
        XCTAssertTrue(g.beforeTool(fill("Serial or asset tag", "C123"), ctx).isEmpty, "only login-like fields are checked")
        ctx.messages = [ChatMessage(role: .assistant, content: "I will use admin")]
        XCTAssertFalse(g.beforeTool(fill("Username", "admin"), ctx).isEmpty, "the bot's own words don't count")
        ctx.messages.append(ChatMessage(role: .user, content: "log in as Jdoe please"))
        XCTAssertTrue(g.beforeTool(fill("Username or email", "jdoe"), ctx).isEmpty)
        ctx.messages.append(ChatMessage(role: .tool, content: "{\"values\":{\"SITE_USERNAME\":\"svc-box\"}}"))
        XCTAssertTrue(g.beforeTool(fill("User name", "svc-box"), ctx).isEmpty)
    }

    func testASecretIsTypedOnlyAfterTheFieldWasClicked() {
        let g = FocusBeforeSecretGuard(); let ctx = RunContext()
        let secret = ToolCall(name: "type_secret", arguments: ["name": AnyCodable("SITE_PASSWORD")])
        XCTAssertFalse(g.beforeTool(secret, ctx).isEmpty)
        _ = g.afterTool(at("move_mouse", 5, 5), ran(), ctx)
        XCTAssertFalse(g.beforeTool(secret, ctx).isEmpty, "hovering is not focus")
        _ = g.afterTool(call("click_text"), ran(), ctx)
        XCTAssertTrue(g.beforeTool(secret, ctx).isEmpty)
        _ = g.afterTool(key("Return"), ran(), ctx)
        XCTAssertFalse(g.beforeTool(secret, ctx).isEmpty, "after a submit the page is new")
        _ = g.afterTool(key("Tab"), ran(), ctx)
        XCTAssertTrue(g.beforeTool(secret, ctx).isEmpty)
    }

    func testAClickWaitsForThePointerToBeMovedOntoTheTarget() {
        let g = AimFirstGuard(); let ctx = RunContext()
        guard case .replaceResult(let json, let kind)? = g.beforeTool(at("click", 200, 300), ctx).first else { return XCTFail("clicked unaimed") }
        XCTAssertEqual(kind, "aim_first"); XCTAssertTrue(json.contains("move_mouse"))
        XCTAssertFalse(g.beforeTool(ToolCall(name: "click", arguments: [:]), ctx).isEmpty, "a click with no coordinates needs an aim too")
        _ = g.afterTool(at("move_mouse", 200, 300), ran(), ctx)
        XCTAssertTrue(g.beforeTool(ToolCall(name: "click", arguments: [:]), ctx).isEmpty)
        XCTAssertTrue(g.beforeTool(at("click", 203, 298), ctx).isEmpty, "a few pixels either way is the same spot")
        XCTAssertFalse(g.beforeTool(at("click", 400, 300), ctx).isEmpty, "a different spot than the pointer is on")
    }

    func testEachClickIsAimedAfreshAndAScreenshotKeepsTheAim() {
        let g = AimFirstGuard(); let ctx = RunContext()
        _ = g.afterTool(at("move_mouse", 10, 10), ran(), ctx)
        _ = g.afterTool(call("screenshot"), ran(), ctx)
        XCTAssertTrue(g.beforeTool(at("click", 10, 10), ctx).isEmpty)
        _ = g.afterTool(at("click", 10, 10), ran(), ctx)
        XCTAssertFalse(g.beforeTool(at("click", 10, 10), ctx).isEmpty)
        _ = g.afterTool(at("move_mouse", 10, 10), ran(["error": "no display"]), ctx)
        XCTAssertFalse(g.beforeTool(at("click", 10, 10), ctx).isEmpty, "a failed move aims nothing")
    }

    func testAKeyPressNeedsAScreenshotBeforeAndShowsOneAfter() {
        let g = LookFirstGuard(); let ctx = RunContext()
        _ = g.afterTool(call("screenshot"), ran(), ctx)
        XCTAssertTrue(g.beforeTool(key("Return"), ctx).isEmpty)
        _ = g.afterTool(key("Return"), ran(["ok": true, "screenshot": "s.png"]), ctx)
        XCTAssertTrue(g.beforeTool(call("click_text"), ctx).isEmpty, "the key's own screenshot is the next before")
        _ = g.afterTool(call("type_secret"), ran(), ctx)
        XCTAssertFalse(g.beforeTool(key("Return"), ctx).isEmpty, "a secret typed shows nothing: look before submitting")
        _ = g.afterTool(call("screenshot"), ran(), ctx)
        _ = g.afterTool(key("Return"), ran(["ok": true, "screenshot_error": "x"]), ctx)
        XCTAssertFalse(g.beforeTool(call("fill_field"), ctx).isEmpty, "no screenshot came back, so look again")
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
