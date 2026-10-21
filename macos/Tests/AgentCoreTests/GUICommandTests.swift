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

/// The realistic click script, run for real against a fake `xdotool` that records what it is told.
final class ClickScriptTests: XCTestCase {
    private func run(from start: (Int, Int), to target: (Int, Int)) throws -> (log: [String], report: [String: Any]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("log"), pos = dir.appendingPathComponent("pos")
        try "\(start.0),\(start.1)".write(to: pos, atomically: true, encoding: .utf8)
        let fake = """
        #!/bin/sh
        echo "$@" >> '\(log.path)'
        case "$1" in
          getmouselocation) p=$(cat '\(pos.path)'); echo "X=${p%,*}"; echo "Y=${p#*,}"; echo "SCREEN=0"; echo "WINDOW=42" ;;
          mousemove) shift; [ "$1" = "--sync" ] && shift; echo "$1,$2" > '\(pos.path)' ;;
          getwindowname) echo "Sign in" ;;
        esac
        """
        let tool = dir.appendingPathComponent("xdotool")
        try fake.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", GUICommand.click(x: target.0, y: target.1, button: 1)]
        p.environment = ["PATH": dir.path + ":/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "DISPLAY": ":1"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let report = (try? JSONSerialization.jsonObject(with: Data((text.split(separator: "\n").last.map(String.init) ?? "{}").utf8))) as? [String: Any] ?? [:]
        return (((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init), report)
    }

    func testThePointerTravelsSettlesPressesHoldsAndReleases() throws {
        let (log, report) = try run(from: (10, 10), to: (300, 200))
        let moves = log.filter { $0.hasPrefix("mousemove") }
        XCTAssertGreaterThan(moves.count, 8, "a path, not a jump")
        let down = log.firstIndex(of: "mousedown 1"), up = log.firstIndex(of: "mouseup 1")
        XCTAssertNotNil(down); XCTAssertNotNil(up)
        if let down, let up { XCTAssertLessThan(down, up) }
        if let down { XCTAssertEqual(log[down - 1], "mousemove --sync 300 200", "it is back exactly on the target just before the press") }
        XCTAssertEqual((report["pointer"] as? [String: Int])?["x"], 300)
        XCTAssertEqual(report["landed"] as? Bool, true)
        XCTAssertEqual(report["window"] as? String, "Sign in")
    }

    func testAClickOnTheSpotItIsAlreadyOnStillPresses() throws {
        let (log, report) = try run(from: (50, 60), to: (50, 60))
        XCTAssertTrue(log.contains("mousedown 1") && log.contains("mouseup 1"))
        XCTAssertEqual(report["landed"] as? Bool, true)
    }
}
