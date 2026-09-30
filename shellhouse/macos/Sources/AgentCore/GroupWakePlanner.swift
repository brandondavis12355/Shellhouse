import Foundation

/// Decides, for ONE member of a group chat, whether the messages it hasn't
/// seen yet should wake it — and how. Pure so the conversation-flow rules
/// (who must answer, when bot-to-bot chatter stops) are unit-testable
/// without any UI, model, or sandbox.
public enum GroupWakePlanner {
    public struct Message: Sendable, Equatable {
        /// `nil` = the human user.
        public var authorID: String?
        public var mentionedIDs: Set<String>
        /// App-generated notices ("Step 2 done", "Goal paused"). Never wake
        /// anyone and never count toward bot-to-bot chatter.
        public var isSystem: Bool
        public init(authorID: String?, mentionedIDs: Set<String>, isSystem: Bool = false) {
            self.authorID = authorID
            self.mentionedIDs = mentionedIDs
            self.isSystem = isSystem
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Nothing new for this member (or the bot-to-bot cap was hit).
        case none
        /// The user @mentioned this member (or @everyone): must reply.
        case mustReply
        /// Another bot @mentioned this member: reply if there's something
        /// to do or add, otherwise it may stay silent (so pure
        /// acknowledgements don't ping-pong forever).
        case mentionedByBot
        /// New messages but no mention: let the member decide whether it
        /// has anything necessary to add.
        case optional
    }

    /// Consecutive bot-authored messages allowed after the last user
    /// message before bots stop waking each other. Only a new user
    /// message resets it — the backstop against endless bot-to-bot loops.
    public static let maxBotMessagesPerUserMessage = 40

    /// - Parameter goalStatus: the group's live goal status, if any. With a
    ///   goal, stalling is tracked by the goal's own progress counter (not
    ///   the flat message cap), a paused goal only wakes for the user, and a
    ///   goal awaiting the user's confirmation only wakes @mentioned bots.
    public static func decide(
        botID: String,
        messages: [Message],
        seenCount: Int,
        maxBotMessages: Int = maxBotMessagesPerUserMessage,
        goalStatus: GroupGoal.Status? = nil
    ) -> Decision {
        let seen = min(max(seenCount, 0), messages.count)
        let pending = messages[seen...].filter { $0.authorID != botID && !$0.isSystem }
        guard !pending.isEmpty else { return .none }

        let pendingHasUser = pending.contains { $0.authorID == nil }
        let liveGoal = goalStatus == .active || goalStatus == .awaitingConfirmation || goalStatus == .paused

        if goalStatus == .paused && !pendingHasUser { return .none }

        if !liveGoal && !pendingHasUser {
            var botTail = 0
            for message in messages.reversed() where !message.isSystem {
                if message.authorID == nil { break }
                botTail += 1
            }
            if botTail >= maxBotMessages { return .none }
        }

        let decision: Decision
        if pending.contains(where: { $0.authorID == nil && $0.mentionedIDs.contains(botID) }) { decision = .mustReply }
        else if pending.contains(where: { $0.authorID != nil && $0.mentionedIDs.contains(botID) }) { decision = .mentionedByBot }
        else { decision = .optional }

        if goalStatus == .awaitingConfirmation && decision == .optional { return .none }
        return decision
    }
}
