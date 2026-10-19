import Foundation

/// Keeps the prompt inside the model's window and the run inside its step budget: asks the runtime to condense the
/// context when it nears the limit, warns as the iteration limit nears, and restates the task every few steps
/// (Manus-style recitation, at the END of the context where the model pays the most attention).
public final class ContextBudgetGuard: Guard {
    public let id = "context_budget"
    private var warningsSent = Set<Int>()

    public init() {}

    public func reset(_ scope: GuardReset) {
        if scope == .run { warningsSent = [] }
    }

    public func beforeModel(_ ctx: RunContext) -> [GuardAction] {
        var actions: [GuardAction] = []
        if let request = condensation(ctx) { actions.append(request) }
        if Reliability.isOn(.taskFocus), let warning = StepBudget.warning(iteration: ctx.iteration, max: ctx.maxIterations),
           warningsSent.insert(warning.id).inserted {
            actions.append(.nudge(Nudge(kind: "budget_warning", text: "[budget] " + warning.text, escalation: warning.id == 2 ? .specific : .soft)))
        }
        // Earlier reminders stay where they are: removing one shifts everything after it, which makes the model
        // server re-read the conversation from that point instead of reusing its cache.
        if Reliability.isOn(.taskFocus), ctx.iteration > 1, ctx.iteration % 5 == 0, !ctx.goal.isEmpty {
            actions.append(.nudge(Nudge(kind: "reminder", text: "[reminder] Your task: \(String(ctx.goal.prefix(400))). "
                + "Step \(ctx.iteration) of \(ctx.maxIterations). Stay on this task; when it is answered, call finish_task."
                + (ctx.plan.isEmpty ? "" : "\nYour plan:\n" + AgentRuntime.PlanItem.text(of: ctx.plan)))))
        }
        return actions
    }

    private func condensation(_ ctx: RunContext) -> GuardAction? {
        let estimate = ContextBudget.estimatedTokens(for:)
        let threshold = ctx.compactionThresholdTokens > 0 ? ctx.compactionThresholdTokens
            : ContextBudget.threshold(window: ctx.contextWindow, schemaTokens: ctx.schemaTokens,
                                      fixedPrefixTokens: ctx.messages.first.map(estimate) ?? 0)
        let estimatedTotal = ctx.messages.reduce(0) { $0 + estimate($1) }
        // The server's own count of the last prompt catches what the estimate misses (tool definitions,
        // formatting); it includes the schemas, so compare it against the whole usable window.
        let reported = ctx.lastPromptTokens - ctx.schemaTokens
        let size = max(estimatedTotal, reported)
        guard size > threshold else { return nil }
        // Just condensed: unless the context is close to the window itself, let the bot work a few steps first.
        // Doing it every step is slow and each summary of a summary loses more of what it had found.
        let hardLimit = Int(Double(ctx.contextWindow - ctx.schemaTokens - ContextBudget.replyReserve) * 0.9)
        if let last = ctx.lastCompactionMessageCount, ctx.messages.count < last + 8, size < hardLimit { return nil }
        return .condense(threshold: threshold, estimatedTokens: size)
    }
}
