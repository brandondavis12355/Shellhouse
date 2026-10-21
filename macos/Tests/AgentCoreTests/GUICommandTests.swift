import XCTest
@testable import AgentCore

final class GUICommandTests: XCTestCase {
    func testEveryDesktopCommandSetsTheDisplay() {
        XCTAssertTrue(GUICommand.wrap("xdotool key Return").hasPrefix("export DISPLAY=\"${DISPLAY:-:1}\"; "))
        XCTAssertTrue(GUICommand.openApp(process: "chromium", launch: "chromium 'http://x'").contains("DISPLAY"))
    }

    func testWrapKeepsADisplayThatIsAlreadySet() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", GUICommand.wrap("printf %s \"$DISPLAY\"")]
        let out = Pipe(); p.standardOutput = out
        p.environment = ["DISPLAY": ":7"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), ":7")
        let q = Process(); q.executableURL = p.executableURL; q.arguments = p.arguments; q.environment = [:]
        let out2 = Pipe(); q.standardOutput = out2
        try q.run(); q.waitUntilExit()
        XCTAssertEqual(String(data: out2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), ":1")
    }

    func testAMissingDesktopIsOneSentenceNotATraceback() {
        let traceback = "Traceback (most recent call last):\n  File \"/usr/local/bin/ai-click.py\", line 54, in main\n    xdotool getmouselocation\nsubprocess.CalledProcessError: Command '['xdotool', 'getmouselocation', '--shell']' returned non-zero exit status 1.\n"
        XCTAssertEqual(GUICommand.failure(traceback), GUICommand.noDesktopMessage)
        XCTAssertEqual(GUICommand.failure("Error: Can't open display: (null)\nFailed creating new xdo instance\n"), GUICommand.noDesktopMessage)
        XCTAssertEqual(GUICommand.failure("[1:1:ERROR] Missing X server or $DISPLAY"), GUICommand.noDesktopMessage)
        XCTAssertEqual(GUICommand.failure("", exitCode: 4, app: "browser"), GUICommand.noDesktopMessage)
    }

    func testAnAppThatDidNotStartIsSaidSoAndOtherErrorsPassThrough() {
        XCTAssertTrue(GUICommand.failure("", exitCode: 5, app: "browser").contains("did not start"))
        XCTAssertEqual(GUICommand.failure("no window matching that title"), "no window matching that title")
        XCTAssertEqual(GUICommand.failure("Traceback (most recent call last):\n  boom\nValueError: bad"), "ValueError: bad")
    }

    func testOpenAppScriptChecksTheDisplayThenTheProcess() {
        let script = GUICommand.openApp(process: "thunar", launch: "thunar /workspace")
        XCTAssertTrue(script.contains("xdotool getdisplaygeometry"))
        XCTAssertTrue(script.contains("exit 4"))
        XCTAssertTrue(script.contains("pgrep -x thunar"))
        XCTAssertTrue(script.hasSuffix("exit 5"))
    }

    /// Runs the real open-app script with a fake `xdotool`, `pgrep` and launcher, to see what it does on a second call.
    private func runOpen(_ script: String, in dir: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PATH": dir.path + ":/usr/bin:/bin", "DISPLAY": ":9"]
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    func testTheSamePageIsNotOpenedTwiceButAnotherPageIs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-once-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(atPath: "/tmp/.shellhouse-opened-fakebrowser") }
        func tool(_ name: String, _ body: String) throws {
            let url = dir.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try tool("xdotool", "exit 0")
        try tool("pgrep", "exit 0")                                  // the browser is running
        try tool("fakebrowser", "echo \"$@\" >> \(dir.path)/launches")
        try? FileManager.default.removeItem(atPath: "/tmp/.shellhouse-opened-fakebrowser")
        func open(_ url: String) -> String {
            GUICommand.openApp(process: "fakebrowser", launch: "fakebrowser \(shellQuote(url))", once: url)
        }
        XCTAssertEqual(try runOpen(open("http://a/x"), in: dir), 0, "first time: opened")
        XCTAssertEqual(try runOpen(open("http://a/x"), in: dir), Int32(GUICommand.alreadyOpenExit), "same page again: not opened")
        XCTAssertEqual(try runOpen(open("http://a/y"), in: dir), 0, "another page: opened")
        XCTAssertEqual(try runOpen(open("http://a/x"), in: dir), 0, "back to the first after a different one: opened")
        let launches = (try String(contentsOf: dir.appendingPathComponent("launches"), encoding: .utf8)).split(separator: "\n")
        XCTAssertEqual(launches.count, 3)
    }

    func testTheTunnelBacksOffAndResetsAfterAGoodRun() {
        let waits = (1...8).map { SSHTunnel.restartDelaySeconds(failureStreak: $0, quick: false) }
        XCTAssertEqual(waits, [5, 10, 20, 40, 60, 60, 60, 60])
        XCTAssertEqual(SSHTunnel.restartDelaySeconds(failureStreak: 0, quick: true), 1)
    }
}
