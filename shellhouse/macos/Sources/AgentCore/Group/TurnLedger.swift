import Foundation

// Keeps score for every human message: who was supposed to answer, who did, who passed, who
// failed. This is what makes "a message nobody answered" impossible to miss, and what lets a
// roll call take turns.

public enum TurnOutcome: Sendable, Equatable {
    case pending
    case replied
    case passed(String)
    case failed(String)

    var isSettled: Bool { if case .pending = self { return false } else { return true } }
}

public enum LedgerAction: Sendable, Equatable {
    /// A member that was guaranteed to answer could not: tell the room (never fail silently).
    case failureNotice(botID: String, reason: String)
    /// Nobody answered and a reply was owed: this member answers now.
    case fallback(botID: String)
}

public struct TurnLedger: Sendable {
    struct Entry {
        var plan: TurnPlan
        var outcomes: [String: TurnOutcome]
        var fallbackIssued = false
        var noticed: Set<String> = []
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 60) { self.capacity = capacity }

    public func isTracking(_ messageID: String) -> Bool { entries[messageID] != nil }

    /// Start tracking a message. Members without an obligation are not waited for.
    public mutating func begin(messageID: String, plan: TurnPlan) {
        var outcomes: [String: TurnOutcome] = [:]
        for (id, p) in plan.plans where p.obligation != .none { outcomes[id] = .pending }
        entries[messageID] = Entry(plan: plan, outcomes: outcomes)
        order.append(messageID)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    public mutating func record(messageID: String, botID: String, _ outcome: TurnOutcome) {
        guard entries[messageID] != nil else { return }
        // An answer already given is never downgraded by a later pass.
        if entries[messageID]?.outcomes[botID] == .replied, outcome != .replied { return }
        entries[messageID]?.outcomes[botID] = outcome
    }

    /// A member left the group (or was deleted) mid-turn: stop waiting for it everywhere.
    public mutating func memberLeft(_ botID: String) {
        for id in order where entries[id]?.outcomes[botID] == .pending {
            entries[id]?.outcomes[botID] = .passed("left the group")
        }
    }

    public func plan(messageID: String) -> TurnPlan? { entries[messageID]?.plan }

    public func outcome(messageID: String, botID: String) -> TurnOutcome? { entries[messageID]?.outcomes[botID] }

    public func isSettled(messageID: String) -> Bool {
        guard let e = entries[messageID] else { return true }
        return e.outcomes.values.allSatisfy(\.isSettled)
    }

    public func hasReply(messageID: String) -> Bool {
        entries[messageID]?.outcomes.values.contains(.replied) ?? false
    }

    /// Roll call: a member may start once everyone before it has finished (replied, passed or failed).
    public func canProceed(messageID: String, botID: String) -> Bool {
        guard let e = entries[messageID], e.plan.isSequential, let index = e.plan.rollCall.firstIndex(of: botID) else { return true }
        return e.plan.rollCall[..<index].allSatisfy { e.outcomes[$0]?.isSettled ?? true }
    }

    /// What still has to happen once everyone has finished. Each action is handed out once.
    public mutating func actionsAfterSettling(messageID: String) -> [LedgerAction] {
        guard var e = entries[messageID], e.outcomes.values.allSatisfy(\.isSettled) else { return [] }
        var actions: [LedgerAction] = []
        var anyFailureOfRequiredMember = false

        for (id, outcome) in e.outcomes.sorted(by: { $0.key < $1.key }) {
            guard case .failed(let why) = outcome, e.plan.obligation(of: id) == .mustReply else { continue }
            anyFailureOfRequiredMember = true
            if e.noticed.insert(id).inserted { actions.append(.failureNotice(botID: id, reason: why)) }
        }
        let anyReply = e.outcomes.values.contains(.replied)
        if !anyReply, !e.plan.isAcknowledgement, !anyFailureOfRequiredMember, !e.fallbackIssued, let floor = e.plan.floorResponderID {
            e.fallbackIssued = true
            actions.append(.fallback(botID: floor))
        }
        entries[messageID] = e
        return actions
    }

    /// A fallback or retry is about to run: wait for it before declaring the message settled.
    public mutating func reopen(messageID: String, botID: String) {
        entries[messageID]?.outcomes[botID] = .pending
    }
}
