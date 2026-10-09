import XCTest
@testable import AgentCore

final class TunnelDiagnosticsTests: XCTestCase {
    func testTheRemoteForwardFailureIsExplained() {
        let e = TunnelDiagnostics.explain("Error: remote port forwarding failed for listen port 18434")
        XCTAssertEqual(e?.key, "remote-forward-18434")
        XCTAssertTrue(e?.text.contains("older tunnel session") == true)
        XCTAssertTrue(e?.text.contains("enable-model-proxy-forward.sh") == true)
    }

    func testOtherKnownFailuresGetAdvice() {
        XCTAssertEqual(TunnelDiagnostics.explain("alex-dev@192.0.2.10: Permission denied (publickey,password).")?.key, "auth")
        XCTAssertEqual(TunnelDiagnostics.explain("Load key \"/Users/x/.ssh/id_ed25519\": Operation not permitted")?.key, "sandbox-ssh")
        XCTAssertEqual(TunnelDiagnostics.explain("ssh: connect to host 10.0.0.5 port 22: Operation timed out")?.key == nil, true)
        XCTAssertEqual(TunnelDiagnostics.explain("ssh: connect to host 10.0.0.5 port 22: Connection timed out")?.key, "unreachable")
        XCTAssertEqual(TunnelDiagnostics.explain("Host key verification failed.")?.key, "hostkey")
        XCTAssertNil(TunnelDiagnostics.explain("Warning: Permanently added 'x' to the list of known hosts."))
    }

    func testRepeatsAreSilencedThenShownAgain() {
        var d = TunnelDiagnostics(repeatEvery: 120)
        let line = "Error: remote port forwarding failed for listen port 18434"
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(d.lineToShow(line, now: t0)?.contains("→") == true, "first time: raw line plus explanation")
        XCTAssertNil(d.lineToShow(line, now: t0.addingTimeInterval(20)))
        XCTAssertNil(d.lineToShow(line, now: t0.addingTimeInterval(100)))
        XCTAssertNotNil(d.lineToShow(line, now: t0.addingTimeInterval(125)))
    }

    func testUnknownLinesAlwaysPassThroughAndKindsAreIndependent() {
        var d = TunnelDiagnostics()
        XCTAssertEqual(d.lineToShow("something unexpected"), "something unexpected")
        XCTAssertEqual(d.lineToShow("something unexpected"), "something unexpected")
        XCTAssertNotNil(d.lineToShow("alex-dev@h: Permission denied (publickey)."))
        XCTAssertNotNil(d.lineToShow("Error: remote port forwarding failed for listen port 18434"), "different kind not silenced by another")
    }
}
