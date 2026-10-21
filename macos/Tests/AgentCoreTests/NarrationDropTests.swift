import XCTest
@testable import AgentCore

final class NarrationDropTests: XCTestCase {
    private func step(_ i: Int, narration: String = "Let me click") -> [ChatMessage] {
        [ChatMessage(role: .assistant, content: "\(narration) \(i)", toolCalls: [ToolCall(name: "click", arguments: ["x": AnyCodable(i)])]),
         ChatMessage(role: .tool, content: "{\"ok\":true}", toolName: "click")]
    }
    private func narrations(_ messages: [ChatMessage]) -> [String] {
        messages.filter { $0.role == .assistant && !($0.toolCalls ?? []).isEmpty }.map(\.content)
    }

    func testOldNarrationLeavesInBatchesAndTheNewestStays() {
        var messages = [ChatMessage(role: .user, content: "do it")]
        for i in 0..<20 { messages += step(i) }
        let out = ObservationPolicy.dropStaleNarration(messages, keep: 4, batch: 6)
        let kept = narrations(out).filter { !$0.isEmpty }
        XCTAssertEqual(kept.suffix(4), ["Let me click 16", "Let me click 17", "Let me click 18", "Let me click 19"])
        XCTAssertEqual(kept.count, 4 + (20 - 4) % 6, "dropped in whole batches of six: ten went, ten stayed")
        XCTAssertEqual(out.filter { $0.role == .assistant && !($0.toolCalls ?? []).isEmpty }.count, 20, "every call is still there")
        XCTAssertEqual(out.first?.content, "do it")
    }

    func testTheStartOfThePromptOnlyChangesInJumps() {
        var messages = [ChatMessage(role: .user, content: "go")]
        var changes = 0, previous: [String] = []
        for i in 0..<30 {
            messages += step(i)
            let now = narrations(ObservationPolicy.dropStaleNarration(messages, keep: 4, batch: 6))
            if !previous.isEmpty, Array(now.prefix(previous.count)) != previous { changes += 1 }
            previous = now
        }
        XCTAssertLessThanOrEqual(changes, 5, "about once per six steps, not every step")
    }

    func testAnswersAndShortRunsAreNeverTouched() {
        let answer = ChatMessage(role: .assistant, content: "Logged in. The page shows the dashboard.")
        var messages = [ChatMessage(role: .user, content: "go")] + step(1) + step(2) + [answer]
        XCTAssertEqual(ObservationPolicy.dropStaleNarration(messages).map(\.content), messages.map(\.content), "fewer than keep + batch: unchanged")
        for i in 3..<30 { messages += step(i) }
        messages.append(answer)
        let out = ObservationPolicy.dropStaleNarration(messages)
        XCTAssertEqual(out.last?.content, answer.content)
        XCTAssertEqual(out.filter { $0.content == answer.content }.count, 2, "a reply with no tool call is an answer")
    }

    func testTheViewDropsItButTheLogKeepsEveryWord() {
        var log = RunLog()
        log.append(.userMessage(content: "go", images: nil))
        for i in 0..<20 { for m in step(i) { log.append(m.role == .tool ? .toolResult(name: "click", content: m.content) : .modelReply(m)) } }
        let rendered = ContextView().render(log.events).messages
        XCTAssertLessThan(narrations(rendered).filter { !$0.isEmpty }.count, 20)
        let inLog = log.events.compactMap { event -> String? in if case .modelReply(let m) = event.kind { return m.content } else { return nil } }
        XCTAssertEqual(inLog.count, 20)
        XCTAssertTrue(inLog.allSatisfy { !$0.isEmpty }, "the log is append-only: nothing was edited")
        XCTAssertEqual(ContextView().render(log.events).messages.map(\.content), rendered.map(\.content), "same log, same prompt")
    }
}
