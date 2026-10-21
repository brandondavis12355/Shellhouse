import Foundation

/// A reply with no tool call: announcing a step instead of taking it, or just talking. Counts the replies in a row
/// that ran nothing (`StuckDetector`), picks the nudge (soft first, then naming the tools), and stops the run at the
/// fifth. A reply that is a real answer ends a chat-style turn instead.
public final class NarrationGuard: Guard {
    public let id = "narration"
    public static let plainReplyMinLength = 25

    private let plainReplyEndsTurn: Bool
    private let answerEndsTurnAfterTools: Bool
    private var stuck = StuckDetector()
    /// The text of a reply that announced a step without taking it: if the model repeats it next to the call, show it once.
    private var lastNarration: String?

    public init(plainReplyEndsTurn: Bool = false, answerEndsTurnAfterTools: Bool = false) {
        self.plainReplyEndsTurn = plainReplyEndsTurn
        self.answerEndsTurnAfterTools = answerEndsTurnAfterTools
    }

    public func reset(_ scope: GuardReset) {
        if scope == .conversation { stuck = StuckDetector() }
    }

    public func afterReply(_ reply: ModelReply, cutOff: Bool, _ ctx: RunContext) -> [GuardAction] {
        if cutOff {
            return noAction(kind: "repetition_cut", escalation: .specific, text: Self.repetitionCutNudge)
        }
        let calls = reply.message.toolCalls ?? []
        let text = reply.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        var actions: [GuardAction] = []
        if let narrated = lastNarration, !text.isEmpty, text == narrated, !calls.isEmpty { actions.append(.hideReplyText) }
        lastNarration = nil
        guard calls.isEmpty else { return actions }

        let announced = ReplyQuality.isAnnouncement(text)
        // An announcement is not an answer, including on a chat turn that otherwise accepts prose.
        let isAnswer = text.count >= Self.plainReplyMinLength && !text.hasSuffix(":") && !announced
        let answeredAfterWork = answerEndsTurnAfterTools && ctx.toolCallsThisTurn > 0
        if isAnswer, plainReplyEndsTurn || answeredAfterWork, ctx.openPlanItems.isEmpty {
            return actions + [.endTurn(text)]
        }
        let count = stuck.plainReplyCount + 1
        var kind = "missing_tool"
        var nudge = Self.missingToolNudge
        if announced {
            // Left in the context, that sentence is what a local model copies on the next try.
            lastNarration = text
            actions.append(.dropReply)
            kind = count >= 2 ? "narration_escalated" : "narration"
            nudge = Self.narrationNudge(count: count, narration: text, toolNames: Array(ctx.toolNames))
        }
        return actions + noAction(kind: kind, escalation: count >= 2 ? .specific : .soft, text: nudge)
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        if case .executed = outcome.kind { stuck.clearPlainReplies() }
        return []
    }

    /// A rewritten plan or a call that never executed is the same as saying the step without doing it.
    public func afterTurn(ranTools: Bool, _ ctx: RunContext) -> [GuardAction] {
        ranTools ? [] : noAction(kind: "calls_not_run", escalation: .soft,
            text: "Those calls did not run. Call a tool with valid arguments, or call finish_task if you are done or blocked.")
    }

    /// Counts a model step that ran no tool. The fifth one stops the run. On the third, `StuckDetector` supplies the nudge.
    private func noAction(kind: String, escalation: Escalation, text: String) -> [GuardAction] {
        switch Reliability.isOn(.loopGuards) ? stuck.recordPlainReply() : StuckDetector.Verdict.fine {
        case .abort(let why): return [.abort(why)]
        case .nudge(let monologue): return [.nudge(Nudge(kind: kind, text: monologue, escalation: .specific, skipIfRepeat: true))]
        case .fine: return [.nudge(Nudge(kind: kind, text: text, escalation: escalation, skipIfRepeat: true))]
        }
    }

    // MARK: wording

    static let repetitionCutNudge = "Your last reply repeated the same passage over and over and was cut off. "
        + "Do not write it again. Call the one tool for your next real step now, or if you are blocked call finish_task with outcome blocked and say why."

    static let missingToolNudge = "You did not call a tool. Plain text alone never ends the task — if you are "
        + "not finished, call the next tool you need right now. If the message you just "
        + "wrote already WAS your complete answer, call finish_task right now with that "
        + "SAME content as the summary — do not write a different, shorter, or more "
        + "hesitant response instead of it. Only report being blocked if you genuinely "
        + "are; don't downgrade a complete answer into a \"blocked\" one just because you "
        + "forgot to call finish_task the first time."

    /// Points a screenshot announcement at the tools and the skill, without a shell recipe.
    static func screenshotRoute(for narration: String) -> String {
        let lowered = narration.lowercased()
        guard lowered.contains("screenshot") || lowered.contains("picture") || lowered.contains("capture") else { return "" }
        return " To show the screen, call screenshot, then post_screenshot. Load use_skill(\"desktop-control\") before a GUI action, "
            + "or use_skill(\"sharing-screenshots\") when the user should see the image."
    }

    /// When the narration names what it will click ("click the \"Reports\" tab"), the exact call for it: a model that keeps saying the
    /// step but never makes the call is handed the call to copy.
    static func callHint(for narration: String, toolNames: [String]) -> String {
        guard toolNames.contains("click_text"),
              let match = narration.range(of: #"(?i)\bclick(?:ing)?\b[^"“'.\n]{0,30}["“']([^"”'\n]{1,60})["”']"#, options: .regularExpression) else { return "" }
        let quoted = narration[match]
        guard let open = quoted.firstIndex(where: { "\"“'".contains($0) }),
              let close = quoted[quoted.index(after: open)...].firstIndex(where: { "\"”'".contains($0) }) else { return "" }
        let target = quoted[quoted.index(after: open)..<close]
        let safe = target.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        return " The call for this step is: click_text with {\"text\": \"\(safe)\"}."
    }

    /// First miss asks for the call. From the second miss, name the tools. The count is `plainReplyCount`.
    static func narrationNudge(count: Int, narration: String, toolNames: [String]) -> String {
        if count >= 2 { return escalatedNarrationNudge(narration: narration, toolNames: toolNames) }
        return "Make the tool call for your next step now. No sentence about it first: just the call."
            + screenshotRoute(for: narration) + callHint(for: narration, toolNames: toolNames)
    }

    static func escalatedNarrationNudge(narration: String, toolNames: [String]) -> String {
        var text = "You have described the next step \(2) times without calling a tool. Do not write another sentence: reply with ONLY a tool call. "
            + "Tools you can call: " + toolNames.sorted().prefix(30).joined(separator: ", ") + "."
        text += screenshotRoute(for: narration) + callHint(for: narration, toolNames: toolNames)
        return text
    }
}
