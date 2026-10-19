import XCTest
@testable import AgentCore

/// Runs the real script against throw-away repositories: an origin, a bot's clone, and a second clone that pushes.
final class CheckoutSyncTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("checkout-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func sh(_ command: String, in cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = cwd ?? dir
        p.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": dir.path,
                         "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// workspace/app is a clone of origin.git; `other` is a second clone used to push new commits.
    private func makeRepos() throws {
        try sh("""
        git init -q --bare -b main origin.git && git clone -q origin.git seed && cd seed && echo 1 > a && git add a && git commit -qm one && git push -q origin main
        cd .. && mkdir workspace && git clone -q origin.git workspace/app && git clone -q origin.git other
        """)
    }
    private func pushFromOther() throws {
        try sh("cd other && echo 2 > b && git add b && git commit -qm two && git push -q origin main")
    }
    private func runSync() throws -> String { try sh(CheckoutSync.script(root: dir.appendingPathComponent("workspace").path)) }

    func testACleanBehindBranchIsFastForwarded() throws {
        try makeRepos(); try pushFromOther()
        let report = try runSync()
        XCTAssertTrue(report.contains("app: on main, fast-forwarded 1 commit(s)"), report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspace/app/b").path))
        let note = CheckoutSync.note(forReport: report)
        XCTAssertNotNil(note, "the bot is told what moved")
    }

    func testAnUpToDateCheckoutNeedsNoNote() throws {
        try makeRepos()
        let report = try runSync()
        XCTAssertTrue(report.contains("up to date"), report)
        XCTAssertNil(CheckoutSync.note(forReport: report))
    }

    func testModifiedFilesAreNeverTouched() throws {
        try makeRepos(); try pushFromOther()
        try sh("echo local > workspace/app/a")
        let report = try runSync()
        XCTAssertTrue(report.contains("BEHIND") && report.contains("1 modified"), report)
        XCTAssertEqual(try sh("cat workspace/app/a").trimmingCharacters(in: .whitespacesAndNewlines), "local", "work in progress is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspace/app/b").path))
        XCTAssertTrue(CheckoutSync.note(forReport: report)?.contains("BEHIND") == true)
    }

    func testLocalCommitsAreNotMerged() throws {
        try makeRepos(); try pushFromOther()
        try sh("cd workspace/app && echo mine > c && git add c && git commit -qm mine")
        let report = try runSync()
        XCTAssertTrue(report.contains("BEHIND") && report.contains("ahead 1"), report)
        XCTAssertEqual(try sh("cd workspace/app && git log --oneline | wc -l").trimmingCharacters(in: .whitespacesAndNewlines), "2", "no merge commit")
    }

    func testABranchWithoutUpstreamAndAFailedFetchAreReported() throws {
        try makeRepos()
        try sh("cd workspace/app && git checkout -q -b scratch")
        XCTAssertTrue(try runSync().contains("no upstream branch"))
        try sh("cd workspace/app && git checkout -q main && git remote set-url origin /nonexistent/path")
        let report = try runSync()
        XCTAssertTrue(report.contains("FETCH FAILED"), report)
        XCTAssertNotNil(CheckoutSync.note(forReport: report))
    }

    func testNoRepositoriesIsSilent() throws {
        try sh("mkdir workspace")
        let report = try runSync()
        XCTAssertEqual(report.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}
