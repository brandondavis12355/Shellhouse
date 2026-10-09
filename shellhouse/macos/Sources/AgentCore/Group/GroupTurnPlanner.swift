import Foundation

// The conversation-flow contract for a group chat, decided BEFORE any model is asked:
//   * a message addressed to someone, or to the whole room, gets an answer from them;
//   * a message addressed to nobody in particular still gets answered by someone;
//   * only an acknowledgement ("thanks") may be met with silence.
// Models only decide what to say, never whether a person gets an answer.

public enum Obligation: Int, Sendable, Comparable {
    /// Nothing to do for this member.
    case none = 0
    /// May reply if it has something to add (the reply gate decides).
    case optional = 1
    /// Another bot asked: reply unless there is genuinely nothing to add.
    case shouldReply = 2
    /// Guaranteed reply: no gate, no opt-out, retried on failure.
    case mustReply = 3

    public static func < (lhs: Obligation, rhs: Obligation) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MemberPlan: Sendable, Equatable {
    public var obligation: Obligation
    public var reason: String
}

public struct TurnPlan: Sendable, Equatable {
    public var plans: [String: MemberPlan]
    /// Members who answer one after another, each seeing the previous replies (a roll call for
    /// "hey guys"); empty means everyone may work at the same time.
    public var rollCall: [String]
    /// If nobody replies, this member must (never set for acknowledgements).
    public var floorResponderID: String?
    public var isAcknowledgement: Bool
    public var addressing: Addressing

    public func obligation(of memberID: String) -> Obligation { plans[memberID]?.obligation ?? .none }
    public func reason(of memberID: String) -> String { plans[memberID]?.reason ?? "" }
    public var isSequential: Bool { !rollCall.isEmpty }
    /// Members that are guaranteed to answer.
    public var mustReplyIDs: [String] {
        plans.filter { $0.value.obligation == .mustReply }.map(\.key).sorted()
    }
}

public enum GroupTurnPlanner {
    /// Plan the answers to one HUMAN message (the owner's, or a friend's in a shared group).
    /// - Parameters:
    ///   - explicitMentionIDs: members named with `@` (and every member for `@everyone`).
    ///   - members: in the group's own order, which is also the roll-call order.
    public static func plan(
        forHumanMessage text: String,
        explicitMentionIDs: Set<String>,
        members: [GroupMember],
        coordinatorID: String? = nil
    ) -> TurnPlan {
        let addressing = AddressingAnalyzer.analyze(text: text, members: members, explicitMentionIDs: explicitMentionIDs)
        var plans: [String: MemberPlan] = [:]
        for m in members { plans[m.id] = MemberPlan(obligation: .optional, reason: "new message, no one addressed") }
        var rollCall: [String] = []
        var floor: String?

        let everyoneMentioned = !members.isEmpty && addressing.explicitIDs.count == members.count && members.count > 1

        if addressing.isAcknowledgement {
            // "thanks", "ok 👍", "thanks Tai Lung": nobody has to answer, and nobody is forced to.
            for m in members { plans[m.id] = MemberPlan(obligation: .optional, reason: "acknowledgement: no reply needed") }
        } else if addressing.isCollective || everyoneMentioned {
            // The whole room: everybody answers. Small talk takes turns (each reply builds on the ones
            // before it); real work runs in parallel, because every member works on its own machine.
            for m in members { plans[m.id] = MemberPlan(obligation: .mustReply, reason: "addressed to the whole group") }
            let named = addressing.addressedIDs
            let ordered = members.filter { named.contains($0.id) } + members.filter { !named.contains($0.id) }
            if addressing.isConversational { rollCall = ordered.map(\.id) }
            floor = ordered.first?.id
        } else if !addressing.addressedIDs.isEmpty {
            for id in addressing.explicitIDs { plans[id] = MemberPlan(obligation: .mustReply, reason: "@mentioned") }
            for id in addressing.nameIDs where plans[id]?.obligation != .mustReply {
                plans[id] = MemberPlan(obligation: .mustReply, reason: "addressed by name")
            }
            floor = members.first(where: { addressing.addressedIDs.contains($0.id) })?.id
        } else {
            // Nobody specific: one best-fit member is guaranteed to answer, the rest may chip in.
            let fit = bestFit(for: text, members: members, coordinatorID: coordinatorID)
            if let fit {
                plans[fit] = MemberPlan(obligation: .mustReply, reason: addressing.isAnyoneQuestion ? "asked of anyone: best fit" : "no one addressed: best fit answers")
                floor = fit
            }
        }
        return TurnPlan(plans: plans, rollCall: rollCall, floorResponderID: floor, isAcknowledgement: addressing.isAcknowledgement, addressing: addressing)
    }

    /// The member whose role best matches the message; ties go to the coordinator, then the first member.
    public static func bestFit(for text: String, members: [GroupMember], coordinatorID: String?) -> String? {
        guard !members.isEmpty else { return nil }
        let messageWords = Set(AddressingAnalyzer.words(in: AddressingAnalyzer.normalize(text)).filter { $0.count >= 4 && !AddressingAnalyzer.nameStopWords.contains($0) })
        var best: (id: String, score: Int)?
        for (index, m) in members.enumerated() {
            let roleWords = Set(AddressingAnalyzer.words(in: AddressingAnalyzer.normalize(m.role + " " + m.name)).filter { $0.count >= 4 })
            var score = messageWords.intersection(roleWords).count * 10
            // Stems: "engineering" ~ "engineer".
            for w in messageWords { for r in roleWords where w != r && (w.hasPrefix(r) || r.hasPrefix(w)) && min(w.count, r.count) >= 5 { score += 6 } }
            if m.id == coordinatorID { score += 2 }
            score += max(0, 1 - index)   // tiny nudge toward the first member
            if best == nil || score > best!.score { best = (m.id, score) }
        }
        return best?.id
    }
}
