import XCTest
@testable import AgentCore

/// `-c` is git's config-injection flag only as a global option (and on
/// `clone`); after other subcommands it is an ordinary flag.
final class GitConfigFlagTests: XCTestCase {
    private func rules(_ command: String) -> [String] { ActionClassifier.classifyShell(command).rules }

    func testGlobalConfigFlagStaysStrict() {
        for c in ["git -c core.pager=less log", "git -ccore.fsmonitor=x status", "git -C /workspace/repo -c alias.x=y x",
                  "git --config-env=core.pager=PAGER log", "git clone -c core.hooksPath=/tmp https://example.com/r.git",
                  "git clone --config http.proxy=x https://example.com/r.git"] {
            XCTAssertTrue(rules(c).contains("security.git_exec"), c)
            XCTAssertEqual(ActionClassifier.classifyShell(c).verdict(tainted: true), .deny, c)
        }
    }

    func testSubcommandDashCIsOrdinary() {
        let expected: [(String, String)] = [
            ("git switch -c fix-parser", "exec.git_switch"),
            ("git checkout -b fix-parser", "exec.git_checkout"),
        ]
        for (c, rule) in expected {
            XCTAssertFalse(rules(c).contains("security.git_exec"), c)
            XCTAssertTrue(rules(c).contains(rule), "\(c): \(rules(c))")
        }
        for c in ["git grep -c TODO", "git commit -c HEAD", "git branch -c old new"] {
            XCTAssertFalse(rules(c).contains("security.git_exec"), c)
        }
    }
}
