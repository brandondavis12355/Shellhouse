import XCTest
@testable import AgentCore

final class CredentialRequestTests: XCTestCase {
    private func parse(_ json: String) -> Result<CredentialRequest, CredentialRequest.ParseError> {
        let args = try! JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
        return CredentialRequest.parse(args)
    }

    func testParsesFieldsAndDefaultsToSecret() throws {
        let request = try parse(#"{"reason":"Log in to the vendor portal","fields":[{"name":"PORTAL_USER","label":"Username","secret":false},{"name":"PORTAL_PASSWORD","label":"Password"}]}"#).get()
        XCTAssertEqual(request.fields.map(\.name), ["PORTAL_USER", "PORTAL_PASSWORD"])
        XCTAssertEqual(request.fields.map(\.secret), [false, true])
    }

    func testRejectsBadNamesDuplicatesAndMissingReason() {
        XCTAssertThrowsError(try parse(#"{"reason":"x","fields":[{"name":"my password","label":"p"}]}"#).get())
        XCTAssertThrowsError(try parse(#"{"reason":"x","fields":[{"name":"A_KEY","label":"a"},{"name":"A_KEY","label":"b"}]}"#).get())
        XCTAssertThrowsError(try parse(#"{"fields":[{"name":"A_KEY","label":"a"}]}"#).get())
        XCTAssertThrowsError(try parse(#"{"reason":"x","fields":[]}"#).get())
    }

    func testResultNamesSecretsButNeverValues() {
        let out = CredentialRequest.result(saved: ["PORTAL_PASSWORD"], kept: [], missing: [], plain: ["PORTAL_USER": "pat"], failed: [])
        XCTAssertEqual(out["saved_secrets"] as? [String], ["PORTAL_PASSWORD"])
        XCTAssertEqual((out["values"] as? [String: String])?["PORTAL_USER"], "pat")
        XCTAssertTrue((out["how_to_use"] as? String)?.contains("type_secret") == true)
    }

    func testTypeSecretAlwaysAsksStrictlyEvenWhenTainted() {
        let classification = ActionClassifier.classify(tool: "type_secret", arguments: ["name": AnyCodable("SITE_PASSWORD"), "window": AnyCodable("Sign in")])
        XCTAssertTrue(classification.findings.allSatisfy { $0.clean == .askStrict && $0.tainted == .askStrict })
        XCTAssertEqual(Policy.evaluate(tool: "type_secret"), .requireApproval)
        XCTAssertEqual(Policy.evaluate(tool: "request_credentials"), .allow)
    }
}

final class LoginRequestTests: XCTestCase {
    private func parse(_ json: String) -> Result<CredentialRequest, CredentialRequest.ParseError> {
        CredentialRequest.parseLogin(try! JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8)))
    }

    func testLoginMakesUsernameAndPasswordFields() throws {
        let request = try parse(#"{"service":"My Jira (work)","site":"https://jira.example.com/login","reason":"File the bug"}"#).get()
        XCTAssertEqual(request.fields.map(\.name), ["MY_JIRA_WORK_USERNAME", "MY_JIRA_WORK_PASSWORD"])
        XCTAssertEqual(request.fields.map(\.secret), [false, true])
        XCTAssertEqual(request.kind, .login(service: "My Jira (work)", site: "jira.example.com"))
    }

    func testLoginRejectsBadInput() {
        XCTAssertThrowsError(try parse(#"{"service":"","reason":"x"}"#).get())
        XCTAssertThrowsError(try parse(#"{"service":"Jira","reason":""}"#).get())
        XCTAssertThrowsError(try parse(#"{"service":"Jira","reason":"x","site":"not a domain!"}"#).get())
        XCTAssertThrowsError(try parse(#"{"service":"123","reason":"x"}"#).get())
    }

    func testBotMessagesFromUntrustedRunsGoToTheReviewerNotStraightThrough() {
        var taint = TaintState(); _ = taint.mark(.web)
        let d = GuardrailPolicy.evaluate(tool: "message_bot", arguments: [:], baseline: Policy.evaluate(tool: "message_bot"), taint: taint, config: GuardrailConfig())
        XCTAssertEqual(d.verdict, .ask)
        XCTAssertEqual(Policy.evaluate(tool: "request_login"), .allow)
    }
}
