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

    func testTheTunnelBacksOffAndResetsAfterAGoodRun() {
        let waits = (1...8).map { SSHTunnel.restartDelaySeconds(failureStreak: $0, quick: false) }
        XCTAssertEqual(waits, [5, 10, 20, 40, 60, 60, 60, 60])
        XCTAssertEqual(SSHTunnel.restartDelaySeconds(failureStreak: 0, quick: true), 1)
    }
}
