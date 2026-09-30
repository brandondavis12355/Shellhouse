import Foundation

/// A group chat's current goal: a checklist the members work through, plus
/// the bookkeeping that distinguishes "productive" from "stalled". Pure
/// value type — all rules live here so they're unit-testable; the app layer
/// only persists it and reacts to the results.
public struct GroupGoal: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case active, awaitingConfirmation, paused, done, cancelled
    }

    public enum StepStatus: String, Codable, Sendable {
        case open, inProgress, done, blocked
    }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var text: String
        public var status: StepStatus
        public var assigneeName: String?
        public var evidence: String?
        /// `true` only if the completing turn actually ran a tool. An
        /// unverified "done" is recorded but does not count as progress.
        public var verified: Bool

        public init(id: String = UUID().uuidString, text: String, status: StepStatus = .open,
                    assigneeName: String? = nil, evidence: String? = nil, verified: Bool = false) {
            self.id = id
            self.text = text
            self.status = status
            self.assigneeName = assigneeName
            self.evidence = evidence
            self.verified = verified
        }
    }

    public enum StepUpdateResult: Sendable, Equatable {
        /// A verified completion — resets the stall counter.
        case progress
        /// Recorded, but not counted as progress (no evidence-producing tool call this turn, or not a completion).
        case recorded
        case rejected(String)
    }

    public static let defaultStallLimit = 40
    public static let minEvidenceLength = 20

    public var id: String
    public var title: String
    public var ownerBotID: String
    public var status: Status
    public var steps: [Step]
    /// Bot-authored messages since the last verified progress (or user activity).
    public var messagesSinceProgress: Int
    public var stallLimit: Int
    public var createdAt: Date
    public var pauseSummary: String?
    public var completionSummary: String?
    public var confirmationRequestedAt: Date?

    public init(id: String = UUID().uuidString, title: String, ownerBotID: String, steps: [Step] = [],
                stallLimit: Int = GroupGoal.defaultStallLimit, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.ownerBotID = ownerBotID
        self.status = .active
        self.steps = steps
        self.messagesSinceProgress = 0
        self.stallLimit = max(1, stallLimit)
        self.createdAt = createdAt
    }

    public var isLive: Bool { status == .active || status == .awaitingConfirmation || status == .paused }
    public var doneCount: Int { steps.filter { $0.status == .done }.count }
    public var openSteps: [Step] { steps.filter { $0.status == .open || $0.status == .inProgress || $0.status == .blocked } }

    @discardableResult
    public mutating func addStep(_ text: String) -> Step? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isLive else { return nil }
        let step = Step(text: trimmed)
        steps.append(step)
        return step
    }

    public mutating func removeStep(id: String) {
        steps.removeAll { $0.id == id }
    }

    /// Owner-editable metadata.
    public mutating func setTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { title = trimmed }
    }

    public mutating func updateStep(
        id stepID: String, status newStatus: StepStatus, evidence: String?, assigneeName: String?, turnHadToolCalls: Bool
    ) -> StepUpdateResult {
        guard status == .active else { return .rejected("The goal is \(status.rawValue); steps can't change now.") }
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
            return .rejected("No step with id '\(stepID)'. Call get_goal for the current ids.")
        }
        if let assigneeName, !assigneeName.isEmpty { steps[index].assigneeName = assigneeName }
        if newStatus != .done {
            steps[index].status = newStatus
            if let evidence, !evidence.isEmpty { steps[index].evidence = evidence }
            return .recorded
        }
        let trimmed = (evidence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minEvidenceLength else {
            return .rejected("Marking a step done needs evidence (at least \(Self.minEvidenceLength) characters): what you ran or checked and what it showed.")
        }
        let alreadyDone = steps[index].status == .done
        steps[index].status = .done
        steps[index].evidence = trimmed
        steps[index].verified = turnHadToolCalls
        if turnHadToolCalls && !alreadyDone {
            messagesSinceProgress = 0
            return .progress
        }
        return .recorded
    }

    /// Call for every bot-authored message while active. Returns `true` if
    /// this message tipped the goal into `.paused`.
    @discardableResult
    public mutating func noteBotMessage() -> Bool {
        guard status == .active else { return false }
        messagesSinceProgress += 1
        if messagesSinceProgress >= stallLimit {
            status = .paused
            return true
        }
        return false
    }

    /// The user posted something: resets the counter, and un-pauses.
    public mutating func noteUserActivity() {
        messagesSinceProgress = 0
        if status == .paused { status = .active }
    }

    public mutating func resume() {
        messagesSinceProgress = 0
        if status == .paused { status = .active }
    }

    public mutating func proposeComplete(summary: String, now: Date = Date()) -> StepUpdateResult {
        guard status == .active else { return .rejected("The goal is \(status.rawValue).") }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("A completion summary is required.") }
        let stillOpen = openSteps.filter { $0.status != .blocked }.count
        guard stillOpen == 0 else {
            return .rejected("\(stillOpen) step(s) are still open. Finish them, or mark them blocked with a reason, first.")
        }
        completionSummary = trimmed
        confirmationRequestedAt = now
        status = .awaitingConfirmation
        return .recorded
    }

    /// The user's reply to a completion proposal.
    public mutating func confirmComplete() {
        guard status == .awaitingConfirmation else { return }
        status = .done
    }

    public mutating func rejectCompletion() {
        guard status == .awaitingConfirmation else { return }
        status = .active
        messagesSinceProgress = 0
        completionSummary = nil
        confirmationRequestedAt = nil
    }

    public mutating func cancel() {
        if isLive { status = .cancelled }
    }

    /// True once an unanswered completion proposal has waited `timeout`.
    public func confirmationTimedOut(timeout: TimeInterval, now: Date = Date()) -> Bool {
        guard status == .awaitingConfirmation, let requested = confirmationRequestedAt else { return false }
        return now.timeIntervalSince(requested) >= timeout
    }

    /// Prompt text shown to every member each turn.
    public func promptBlock(ownerName: String) -> String {
        var lines = ["CURRENT GROUP GOAL (owner: \(ownerName), status: \(status.rawValue)): \(title)"]
        for (index, step) in steps.enumerated() {
            let mark: String
            switch step.status {
            case .done: mark = "[x]"
            case .inProgress: mark = "[~]"
            case .blocked: mark = "[!]"
            case .open: mark = "[ ]"
            }
            let assignee = step.assigneeName.map { " (\($0))" } ?? ""
            lines.append("  \(index + 1). \(mark) \(step.text)\(assignee)  id=\(step.id)")
        }
        lines.append("Progress: \(doneCount)/\(steps.count) steps done; \(messagesSinceProgress)/\(stallLimit) messages since last verified progress.")
        return lines.joined(separator: "\n")
    }
}
