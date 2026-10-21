import XCTest
@testable import AgentCore

/// Runs the real script against a real (headless) Chrome on a test page. Skipped where Chrome isn't installed.
final class BrowserControlTests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private var browser: Process?
    private var dir: URL!
    private var port = 0

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.chrome), "Chrome is not installed here")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("browser-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = dir.appendingPathComponent("page.html")
        try """
        <html><head><title>Home</title></head><body>
        <nav><a href="#home">Home</a> <a href="#receive">Receive</a> <a href="#reports" id="r">Reports</a> <a href="#users">Users</a></nav>
        <h1>Find device</h1>
        <label for="serial">Serial or asset tag</label>
        <input id="serial" name="serial" placeholder="Serial or asset tag">
        <button id="go" onclick="document.title='Searched:' + document.getElementById('serial').value">Search</button>
        <a href="#hidden" style="display:none">Hidden link</a>
        <div style="height:3000px"></div>
        <a href="#bottom" id="b">Bottom link</a>
        </body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        port = 19_300 + Int.random(in: 0..<500)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.chrome)
        p.arguments = ["--headless=new", "--disable-gpu", "--remote-debugging-port=\(port)", "--user-data-dir=\(dir.appendingPathComponent("profile").path)",
                       "--no-first-run", "--no-default-browser-check", page.absoluteString]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); browser = p
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/json")!),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], list.contains(where: { ($0["url"] as? String)?.hasSuffix("page.html") == true }) { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw XCTSkip("headless Chrome did not come up")
    }

    override func tearDown() {
        browser?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func run(_ operation: BrowserControl.Operation, _ args: [String]) throws -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", BrowserControl.command(operation, args, port: port)]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (try JSONSerialization.jsonObject(with: Data((text.split(separator: "\n").last.map(String.init) ?? "{}").utf8))) as? [String: Any] ?? [:]
    }

    func testFindReturnsVisibleElementsBestMatchFirst() throws {
        let r = try run(.find, ["reports"])
        let matches = try XCTUnwrap(r["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.first?["label"] as? String, "Reports")
        XCTAssertEqual(matches.first?["tag"] as? String, "a")
        XCTAssertNotNil(matches.first?["x"]); XCTAssertEqual(r["title"] as? String, "Home")
        XCTAssertTrue(try XCTUnwrap(run(.find, ["hidden link"])["matches"] as? [Any]).isEmpty, "an element that isn't shown isn't offered")
    }

    func testClickByTextNavigatesAndSaysSo() throws {
        let r = try run(.click, ["Reports", "0"])
        XCTAssertEqual((r["clicked"] as? [String: Any])?["label"] as? String, "Reports")
        XCTAssertEqual(r["navigated"] as? Bool, true)
        XCTAssertTrue((r["url"] as? String)?.hasSuffix("#reports") == true, "\(r)")
        XCTAssertNotNil((r["pointer"] as? [String: Any])?["x"], "where it clicked, for the pointer shown on the desktop")
    }

    func testAnElementBelowTheFoldIsScrolledToAndClicked() throws {
        let r = try run(.click, ["Bottom link", "0"])
        XCTAssertTrue((r["url"] as? String)?.hasSuffix("#bottom") == true, "\(r)")
    }

    func testFillAFieldByItsLabelThenClickSearch() throws {
        let filled = try run(.fill, ["Serial", "C37302TMW5"])
        XCTAssertEqual(filled["value_length"] as? Int, 10, "\(filled)")
        let clicked = try run(.click, ["Search", "0"])
        XCTAssertEqual(clicked["title"] as? String, "Searched:C37302TMW5", "\(clicked)")
    }

    func testFillReplacesWhatWasThere() throws {
        _ = try run(.fill, ["Serial or asset tag", "first"])
        let again = try run(.fill, ["serial", "second"])
        XCTAssertEqual(again["value_length"] as? Int, 6, "the field holds only the new text: \(again)")
    }

    func testNoMatchSaysSoAndPageTextIsReadable() throws {
        let none = try run(.click, ["Nonexistent thing", "0"])
        XCTAssertEqual(none["error"] as? String, "no_match")
        let text = try run(.text, ["500"])
        XCTAssertTrue((text["text"] as? String)?.contains("Find device") == true, "\(text)")
    }

    func testABrowserWithNoRemotePortIsReportedNotHung() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", BrowserControl.command(.find, ["x"], port: 1)]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("browser_not_controllable"), text)
    }
}
