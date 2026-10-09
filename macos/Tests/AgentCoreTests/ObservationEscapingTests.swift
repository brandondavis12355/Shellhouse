import XCTest
@testable import AgentCore

/// Tool output is stored as JSON (`"\/usr\/bin\/gh"`); paths quoted from it
/// must still count as grounded.
final class ObservationEscapingTests: XCTestCase {
    private let observations = #"{"exit_code":0,"stderr":"","stdout":"\/usr\/bin\/gh\ngh version 2.46.0 (2025-01-13 Debian 2.46.0-3)\n"}"#

    func testClaimCheckFindsEscapedPath() {
        XCTAssertEqual(ClaimCheck.unsupported(in: "gh is at /usr/bin/gh, version 2.46.0.", sources: observations), [])
    }

    func testClaimCheckStillFlagsInventedPath() {
        XCTAssertEqual(ClaimCheck.unsupported(in: "gh is at /opt/gh/bin/gh.", sources: observations), ["/opt/gh/bin/gh"])
    }

    func testEvidenceGroundedByPathAlone() {
        XCTAssertTrue(EvidenceGrounding.isGrounded(evidence: "command -v gh printed /usr/bin/gh", observations: observations))
        XCTAssertFalse(EvidenceGrounding.isGrounded(evidence: "found it at /opt/elsewhere/gh", observations: observations))
    }
}
