import XCTest
@testable import AgentCore

final class RunLogTests: XCTestCase {
    private func big(_ n: Int) -> String { String(repeating: "x", count: n) }

    private func logWithResults(_ count: Int, size: Int = 900) -> RunLog {
        var log = RunLog()
        log.append(.system("SYSTEM PROMPT"))
        log.append(.userMessage(content: "the task", images: nil))
        for i in 0..<count {
            log.append(.modelReply(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "read_file", arguments: ["path": AnyCodable("f\(i)")])])))
            log.append(.toolResult(name: "read_file", content: "result \(i) " + big(size)))
        }
        return log
    }

    func testViewIsAPureFunctionOfTheLog() {
        let log = logWithResults(12)
        let a = ContextView().render(log.events), b = ContextView().render(log.events)
        XCTAssertEqual(a.messages.map(\.content), b.messages.map(\.content))
        XCTAssertEqual(a.sourceIDs, b.sourceIDs)
    }

    func testLogIsNeverEditedByTheViewRules() {
        let log = logWithResults(20)
        _ = ContextView().render(log.events)
        let toolResults = log.events.compactMap { event -> String? in
            if case .toolResult(_, let content) = event.kind { return content }
            return nil
        }
        XCTAssertEqual(toolResults.count, 20)
        XCTAssertTrue(toolResults.allSatisfy { !$0.hasPrefix("[earlier output") }, "old output is stubbed in the view only")
    }

    func testPromptPrefixIsByteIdenticalFromStepToStep() {
        var log = logWithResults(3)
        var previous = ContextView().render(log.events).messages
        for i in 3..<12 {
            log.append(.modelReply(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(name: "read_file", arguments: ["path": AnyCodable("f\(i)")])])))
            log.append(.toolResult(name: "read_file", content: "result \(i) " + big(900)))
            let next = ContextView().render(log.events).messages
            // The system prompt and the task never change.
            XCTAssertEqual(next[0].content, "SYSTEM PROMPT")
            XCTAssertEqual(next[1].content, "the task")
            // Collapsing happens in batches of four: between batches the old part is untouched.
            let stable = zip(previous, next).prefix { $0.content == $1.content }.count
            XCTAssertGreaterThanOrEqual(stable, 2)
            previous = next
        }
    }

    func testCollapseHappensInBatchesNotEveryStep() {
        var log = logWithResults(8)
        var changed = 0
        var previous = ContextView().render(log.events).messages.map(\.content)
        for i in 8..<24 {
            log.append(.modelReply(ChatMessage(role: .assistant, content: "")))
            log.append(.toolResult(name: "read_file", content: "r\(i) " + big(900)))
            let next = ContextView().render(log.events).messages.map(\.content)
            if zip(previous, next).contains(where: { $0 != $1 }) { changed += 1 }
            previous = next
        }
        XCTAssertLessThanOrEqual(changed, 5, "16 new results rewrite old ones in about four batches, not 16 times")
    }

    func testSupersededReplyIsLeftOutOfThePromptButStaysInTheLog() {
        var log = RunLog()
        log.append(.system("s"))
        log.append(.userMessage(content: "task", images: nil))
        let announcement = log.append(.modelReply(ChatMessage(role: .assistant, content: "Let me check the file.")))
        log.append(.nudge(kind: "narration", text: "Make the tool call now.", escalation: 0, supersedes: announcement.id, inContext: true))
        let messages = ContextView().render(log.events).messages
        XCTAssertEqual(messages.map(\.content), ["s", "task", "Make the tool call now."])
        XCTAssertEqual(log.events.count, 4)
    }

    func testOnlyTheNewestScreenshotsKeepTheirPixels() {
        var log = RunLog()
        log.append(.system("s"))
        for i in 0..<4 { log.append(.screenshot(content: "shot \(i)", images: ["img\(i)"])) }
        let messages = ContextView().render(log.events).messages
        XCTAssertEqual(messages.compactMap(\.images).flatMap { $0 }, ["img2", "img3"])
        XCTAssertEqual(messages[1].content, ContextView.prunedScreenshotText)
        XCTAssertEqual(messages[4].content, "shot 3")
    }

    func testSummaryEventReplacesItsRange() {
        var log = logWithResults(6, size: 50)
        let rendered = ContextView().render(log.events)
        // Summarize everything after the task up to the last two messages.
        log.append(.condensed(.summary(first: rendered.sourceIDs[2], last: rendered.sourceIDs[rendered.sourceIDs.count - 3], text: "DIGEST")))
        let after = ContextView().render(log.events)
        XCTAssertEqual(after.messages.count, 2 + 1 + 2)
        XCTAssertEqual(after.messages[0].content, "SYSTEM PROMPT")
        XCTAssertEqual(after.messages[1].content, "the task")
        XCTAssertEqual(after.messages[2].content, ContextView.summaryMessageText("DIGEST"))
        XCTAssertEqual(log.count, 2 + 12 + 1, "the summarized events are still in the log")
    }

    func testCollapseEventStubsOldOutputFromThatPointOn() {
        var log = logWithResults(10, size: 500)
        let before = ContextView(collapseOldOutput: false).render(log.events).messages
        XCTAssertFalse(before.contains { $0.content.hasPrefix("[earlier output") })
        log.append(.condensed(.collapse(keepLast: 4, minCharacters: 400, batch: 1)))
        let after = ContextView(collapseOldOutput: false).render(log.events).messages
        XCTAssertEqual(after.filter { $0.content.hasPrefix("[earlier output") }.count, 6)
    }

    func testJSONLRoundTripDropsImagesAndSkipsTornLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runlog-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = RunLogFileSink(url: url)
        var log = RunLog(sink: sink)
        log.append(.system("sys"))
        log.append(.userMessage(content: "hi", images: ["AAAA"]))
        log.append(.screenshot(content: "shot", images: ["BBBB"]))
        log.append(.nudge(kind: "narration", text: "t", escalation: 1, supersedes: nil, inContext: true))
        log.append(.stateNote("not persisted"), persist: false)
        sink.flush()
        try Data("{not json\n".utf8).append(to: url)
        let loaded = RunLog.load(from: url)
        XCTAssertEqual(loaded.count, 4)
        if case .screenshot(_, let images) = loaded[2].kind { XCTAssertFalse(images.joined().contains("BBBB")) } else { XCTFail("screenshot event") }
        if case .userMessage(_, let images) = loaded[1].kind { XCTAssertFalse((images ?? []).joined().contains("AAAA")) } else { XCTFail("user event") }
        let rendered = ContextView().render(loaded).messages
        XCTAssertEqual(rendered.first?.content, "sys")
    }

    func testOldTranscriptsStayReadable() {
        // The app's transcript is a separate file the log never touches; a log only adds a sibling file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).jsonl")
        XCTAssertTrue(RunLog.load(from: url).isEmpty)
    }

    // MARK: through the runtime

    private final class MemorySink: RunLogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RunEvent] = []
        func write(_ event: RunEvent) { lock.lock(); items.append(event); lock.unlock() }
        var events: [RunEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testRuntimeWritesTheEventsOfARun() async {
        let model = LoopPlanTests.ScriptedForRunLog([
            ChatMessage(role: .assistant, content: "Let me look now."),
            ChatMessage(role: .assistant, content: "", toolCalls: [LoopPlanTests.finish]),
        ])
        let sink = MemorySink()
        let runtime = AgentRuntime(model: model, sandbox: LoopPlanTests.SlowBoxShared(), sandboxID: "t",
                                   budgets: AgentRuntime.Budgets(maxIterations: 10), requestApproval: { _ in .approve }, runLogSink: sink)
        await runtime.start(systemPrompt: "system", goal: "do it")
        let kinds = sink.events.map { event -> String in
            switch event.kind {
            case .system: return "system"
            case .userMessage: return "user"
            case .modelReply: return "reply"
            case .toolResult: return "tool"
            case .nudge(let kind, _, _, _, _): return "nudge:" + kind
            default: return "other"
            }
        }
        XCTAssertEqual(kinds.prefix(3), ["system", "user", "reply"])
        XCTAssertTrue(kinds.contains { $0.hasPrefix("nudge:") }, "the narration correction is in the log: \(kinds)")
        let transcript = await runtime.transcript()
        XCTAssertFalse(transcript.contains { $0.content == "Let me look now." }, "the announcement is left out of the prompt")
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
