import Foundation

/// The guards of a run, in the one order they run in. Order matters where one guard reads another's result:
/// trash warnings annotate a result before the failure and identical-result checks read it, and the stale check
/// runs before the repeat check that asks whether a result was already seen. Nudges reach the model in this order.
public enum GuardSet {
    public static func standard(plainReplyEndsTurn: Bool = false, answerEndsTurnAfterTools: Bool = false,
                                seenResults: SeenResults = SeenResults()) -> [any Guard] {
        let stale = StaleResultsGuard(seen: seenResults)
        return [
            ContextBudgetGuard(),
            ToolCallRecoveryGuard(),
            NarrationGuard(plainReplyEndsTurn: plainReplyEndsTurn, answerEndsTurnAfterTools: answerEndsTurnAfterTools),
            RepeatedCallsGuard(stale: stale),
            ToolValidationGuard(),
            TrashWarningGuard(),
            SameErrorGuard(),
            FailureStreakGuard(),
            stale,
            UnverifiedChangeGuard(),
            EmptySummaryGuard(),
            OpenPlanGuard(),
        ]
    }
}
