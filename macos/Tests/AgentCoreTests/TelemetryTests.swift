import XCTest
@testable import AgentCore

final class TelemetryTests: XCTestCase {
    func testCallsAreAttributedToTheBotAndPurposeInContext() async {
        let recorder = TelemetryRecorder()
        await Telemetry.$context.withValue(TelemetryContext(bot: "Atlas", purpose: "group: Team")) {
            recorder.modelCall(model: "m", promptTokens: 1_000, completionTokens: 200, seconds: 2, generationSeconds: 1)
            recorder.toolRun("run_shell", seconds: 0.5, failed: true)
            recorder.runEnded(stoppedBecause: "max iterations (40) reached")
        }
        recorder.modelCall(model: "m", promptTokens: 10, completionTokens: 5, seconds: 0.1)
        let s = recorder.snapshot()
        XCTAssertEqual(s.byBot["Atlas"]?.model.calls, 1)
        XCTAssertEqual(s.byBot["Atlas"]?.toolFailures, 1)
        XCTAssertEqual(s.byBot["Atlas"]?.runsStopped, 1)
        XCTAssertEqual(s.byPurpose["group turn"]?.promptTokens, 1_000)
        XCTAssertEqual(s.byBot["app"]?.model.calls, 1)
        XCTAssertEqual(s.total.tokensPerSecond, 200)
        XCTAssertEqual(s.stopReasons["max iterations (N) reached"], 1)
        XCTAssertEqual(s.total.calls, 2)
    }

    func testRecentEventsAreBounded() {
        let recorder = TelemetryRecorder()
        for _ in 0..<(TelemetryRecorder.recentLimit + 50) { recorder.toolRun("x", seconds: 0, failed: false) }
        XCTAssertEqual(recorder.snapshot().recent.count, TelemetryRecorder.recentLimit)
    }
}
