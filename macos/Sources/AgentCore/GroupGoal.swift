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
        /// A non-owner says it's finished; only the goal owner can validate it into `done`.
        case review
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
        /// For work every listed member must do on their own VM ("each bot
        /// checks…"): the step is done only once all of them have checked
        /// in. `nil` for an ordinary single-owner step. Optional so goals
        /// saved before this existed still decode.
        public var requiredMembers: [String]?
        /// Who has checked in on a per-member step, and what each saw.
        public var memberEvidence: [String: String]?
        /// Ids of earlier steps that must be done before this one can start. Optional so older goals decode.
        public var dependsOn: [String]?

        public init(id: String = UUID().uuidString, text: String, status: StepStatus = .open,
                    assigneeName: String? = nil, evidence: String? = nil, verified: Bool = false,
                    requiredMembers: [String]? = nil) {
            self.id = id
            self.text = text
            self.status = status
            self.assigneeName = assigneeName
            self.evidence = evidence
            self.verified = verified
            self.requiredMembers = (requiredMembers?.isEmpty ?? true) ? nil : requiredMembers
        }

        public var isPerMember: Bool { !(requiredMembers?.isEmpty ?? true) }

        /// Required members who haven't checked in yet, in their listed order.
        public var membersRemaining: [String] {
            guard let required = requiredMembers else { return [] }
            let done = Set((memberEvidence ?? [:]).keys.map { $0.lowercased() })
            return required.filter { !done.contains($0.lowercased()) }
        }
    }

    /// Which members a step's text says must each do it: every member for
    /// "each bot", "every VM", "all members", "everyone"…; the named ones when
    /// it names two or more. `nil` when it reads as one member's job.
    public static func membersRequired(byStepText text: String, memberNames: [String]) -> [String]? {
        let lower = text.lowercased()
        let named = memberNames.filter { name in
            let n = name.lowercased()
            guard !n.isEmpty else { return false }
            return lower.range(of: "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: n) + "($|[^a-z0-9])",
                               options: .regularExpression) != nil
        }
        if named.count >= 2 { return named }
        let everyone = #"\b(each|every|all)\s+(single\s+)?(of\s+the\s+|of\s+our\s+)?(bot|member|vm|machine|agent|sandbox|computer)s?\b|\beveryone\b|\beverybody\b|\beach of (us|you|them)\b"#
        if lower.range(of: everyone, options: .regularExpression) != nil, memberNames.count >= 2 { return memberNames }
        return nil
    }

    public enum StepUpdateResult: Sendable, Equatable {
        /// A verified completion — resets the stall counter.
        case progress
        /// Recorded, but not counted as progress (no evidence-producing tool call this turn, or not a completion).
        case recorded
        /// A non-owner's "done": held for the owner to validate. Never counts as progress.
        case submitted
        /// One member's verified check-in on a per-member step that still
        /// waits on others. Counts as progress (resets the stall counter).
        case memberCheckedIn(remaining: [String])
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
    /// The member who checks submitted steps and marks them done, when the owner doesn't do that itself
    /// (a manager that only coordinates). `nil`: the owner validates.
    public var validatorName: String?

    /// Whether `name` (the owner if `isOwner`) is the one who validates submissions into `done`.
    public func validates(_ name: String, isOwner: Bool) -> Bool {
        guard let validatorName else { return isOwner }
        return validatorName.caseInsensitiveCompare(name) == .orderedSame
    }

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
    public var openSteps: [Step] { steps.filter { $0.status == .open || $0.status == .inProgress || $0.status == .blocked || $0.status == .review } }

    @discardableResult
    public mutating func addStep(_ text: String, requiredMembers: [String]? = nil, dependsOnNumbers: [Int] = []) -> Step? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isLive else { return nil }
        var step = Step(text: trimmed, requiredMembers: requiredMembers)
        step.dependsOn = Self.ids(forNumbers: dependsOnNumbers, before: steps.count, in: steps)
        steps.append(step)
        return step
    }

    /// Step numbers (1-based, as shown in the goal block) to ids, keeping only earlier steps, so a plan
    /// can never form a cycle.
    static func ids(forNumbers numbers: [Int], before position: Int, in steps: [Step]) -> [String]? {
        let ids = Set(numbers).filter { $0 >= 1 && $0 <= min(position, steps.count) }.sorted().map { steps[$0 - 1].id }
        return ids.isEmpty ? nil : ids
    }

    /// `[{"step": 3, "after": [2]}]` (or `{"3": [2]}`) from a tool call, as step number → numbers it waits on.
    public static func dependencyMap(from value: Any?) -> [Int: [Int]] {
        func unwrap(_ v: Any?) -> Any? { (v as? AnyCodable)?.value ?? v }
        func int(_ v: Any?) -> Int? {
            switch unwrap(v) {
            case let n as Int: return n
            case let n as Double: return Int(n)
            case let n as NSNumber: return n.intValue
            case let t as String: return Int(t.trimmingCharacters(in: .whitespaces))
            default: return nil
            }
        }
        var out: [Int: [Int]] = [:]
        if let list = unwrap(value) as? [Any] {
            for item in list {
                guard let entry = unwrap(item) as? [String: Any], let step = int(entry["step"]) else { continue }
                out[step, default: []] += numbers(from: entry["after"])
            }
        } else if let dict = unwrap(value) as? [String: Any] {
            for (key, after) in dict { if let step = Int(key) { out[step, default: []] += numbers(from: after) } }
        }
        return out
    }

    public static func numbers(from value: Any?) -> [Int] {
        let raw = (value as? AnyCodable)?.value ?? value
        return ((raw as? [Any]) ?? []).compactMap { item in
            let v = (item as? AnyCodable)?.value ?? item
            if let n = v as? Int { return n }
            if let n = v as? Double { return Int(n) }
            if let t = v as? String { return Int(t) }
            return nil
        }
    }

    /// Sets each step's dependencies from `numbers` (step number → the step numbers it waits on). Used when
    /// a goal is proposed; anything pointing at the same or a later step is dropped.
    public mutating func setDependencies(_ numbers: [Int: [Int]]) {
        for (number, after) in numbers where number >= 1 && number <= steps.count {
            steps[number - 1].dependsOn = Self.ids(forNumbers: after, before: number - 1, in: steps)
        }
    }

    /// The steps `stepID` waits on that aren't done yet, with their 1-based numbers.
    public func unmetDependencies(of stepID: String) -> [(number: Int, step: Step)] {
        guard let step = steps.first(where: { $0.id == stepID }) else { return [] }
        return (step.dependsOn ?? []).compactMap { id in
            guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].status != .done else { return nil }
            return (index + 1, steps[index])
        }
    }

    public func isWaiting(_ step: Step) -> Bool { step.status != .done && !unmetDependencies(of: step.id).isEmpty }

    /// `name` has goal work, but all of it waits on other steps: nothing it can do yet.
    public func onlyWaitingWork(for name: String) -> Bool {
        let mine = steps.filter { step in
            guard step.status != .done, step.status != .review else { return false }
            if let required = step.requiredMembers, !required.isEmpty {
                return step.membersRemaining.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            return Self.step(step, belongsTo: name)
        }
        return !mine.isEmpty && mine.allSatisfy(isWaiting)
    }

    /// `name` has a step it can work on right now: assigned to it (or its part of a per-member step), not done,
    /// submitted or blocked, and not waiting on unfinished steps.
    /// A single-member step is `name`'s when it's assigned to them, or unassigned and its text starts "Name: …".
    public static func step(_ step: Step, belongsTo name: String) -> Bool {
        if let assignee = step.assigneeName, !assignee.isEmpty { return assignee.caseInsensitiveCompare(name) == .orderedSame }
        return step.text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(name.lowercased() + ":")
    }

    /// How many steps `name` could work on right now (see `hasActionableWork`).
    public func actionableStepCount(for name: String) -> Int {
        steps.filter { step in
            guard step.status == .open || step.status == .inProgress, !isWaiting(step) else { return false }
            if let required = step.requiredMembers, !required.isEmpty {
                return step.membersRemaining.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            return Self.step(step, belongsTo: name)
        }.count
    }

    public func hasActionableWork(for name: String) -> Bool {
        steps.contains { step in
            guard step.status == .open || step.status == .inProgress, !isWaiting(step) else { return false }
            if let required = step.requiredMembers, !required.isEmpty {
                return step.membersRemaining.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            return Self.step(step, belongsTo: name)
        }
    }

    public mutating func removeStep(id: String) {
        steps.removeAll { $0.id == id }
        for index in steps.indices { steps[index].dependsOn = steps[index].dependsOn?.filter { $0 != id }.nilIfEmpty }
    }

    // MARK: Editing the plan (the user from the goal card; the owner with edit_goal_step)

    @discardableResult
    public mutating func editStep(id: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = steps.firstIndex(where: { $0.id == id }) else { return false }
        steps[index].text = trimmed
        return true
    }

    /// `nil` or empty unassigns.
    @discardableResult
    public mutating func assignStep(id: String, to name: String?) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        steps[index].assigneeName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return true
    }

    /// The user's word is the check: marked done and verified, with the user named as the evidence.
    @discardableResult
    public mutating func markDoneByUser(id: String) -> Bool {
        guard isLive, let index = steps.firstIndex(where: { $0.id == id }) else { return false }
        steps[index].status = .done
        steps[index].verified = true
        steps[index].evidence = "Marked done by the user."
        noteUserActivity()
        return true
    }

    /// Back to open: evidence and check-ins cleared, as if never started.
    @discardableResult
    public mutating func reopenStep(id: String) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return false }
        steps[index].status = .open
        steps[index].verified = false
        steps[index].evidence = nil
        steps[index].memberEvidence = nil
        return true
    }

    /// Moves a step up (negative) or down. Dependencies that would now point at a later step are dropped.
    @discardableResult
    public mutating func moveStep(id: String, by offset: Int) -> Bool {
        guard let from = steps.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(from + offset, 0), steps.count - 1)
        guard to != from else { return false }
        steps.insert(steps.remove(at: from), at: to)
        for index in steps.indices {
            let earlier = Set(steps[..<index].map(\.id))
            steps[index].dependsOn = steps[index].dependsOn?.filter { earlier.contains($0) }.nilIfEmpty
        }
        return true
    }

    /// Replaces what a step waits on, by 1-based step numbers (earlier steps only).
    public mutating func setDependencies(ofStep id: String, numbers: [Int]) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].dependsOn = Self.ids(forNumbers: numbers, before: index, in: steps)
    }

    /// Owner-editable metadata.
    public mutating func setTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { title = trimmed }
    }

    public mutating func updateStep(
        id stepID: String, status newStatus: StepStatus, evidence: String?, assigneeName: String?, turnHadToolCalls: Bool,
        byOwner: Bool = true, actorName: String? = nil
    ) -> StepUpdateResult {
        guard status == .active else { return .rejected("The goal is \(status.rawValue); steps can't change now.") }
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
            return .rejected("No step with id '\(stepID)'. Call get_goal for the current ids.")
        }
        let current = steps[index].status
        let waitingOn = unmetDependencies(of: stepID)
        if newStatus == .inProgress || newStatus == .done, !waitingOn.isEmpty {
            let list = waitingOn.map { "step \($0.number) (\($0.step.text))" }.joined(separator: ", ")
            return .rejected("Step \(index + 1) can't start yet: it waits on \(list), which isn't done. Don't work on it or build "
                + "a stand-in for the missing piece. Say in one line what you're waiting for and stop, or send whoever is doing \(list) what they need.")
        }
        if newStatus == .review {
            return .rejected("'review' is set by the app when a member submits a step; use 'done' with evidence.")
        }
        if !byOwner {
            // Members work steps; only the owner decides they're finished.
            if current == .done { return .rejected("This step is already validated as done by the goal owner.") }
            if current == .review { return .rejected("This step is waiting for the goal owner's validation; only the owner can change it now.") }
        }
        // The same status again is no news: say so, rather than record it and let the bot keep re-announcing it.
        if !steps[index].isPerMember, newStatus == current, newStatus == .blocked || newStatus == .inProgress {
            let state = newStatus == .blocked ? "blocked" : "in progress"
            return .rejected("Step \(index + 1) is already marked \(state); recording it again changes nothing. "
                + (byOwner
                    ? "If a member is waiting on your decision, decide now: post the decision in one line and who does what. "
                    : "")
                + "If you're waiting on someone, say once what you're waiting for and end your turn.")
        }
        if steps[index].isPerMember {
            return updatePerMemberStep(at: index, status: newStatus, evidence: evidence, actorName: actorName,
                                       turnHadToolCalls: turnHadToolCalls)
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
        if !byOwner {
            steps[index].status = .review
            steps[index].evidence = trimmed
            steps[index].verified = false
            return .submitted
        }
        if current == .review, !turnHadToolCalls {
            return .rejected("Validate before accepting: run your own check this turn (re-run the command, read the file, test the result) and then mark it done with what YOU saw.")
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

    /// A per-member step: each listed member checks in their own part with
    /// evidence from their own tools. Nobody can check in for someone else,
    /// and the owner re-running a check on its own VM proves nothing about
    /// another member's, so a member's tool-backed check-in stands on its own.
    private mutating func updatePerMemberStep(
        at index: Int, status newStatus: StepStatus, evidence: String?, actorName: String?, turnHadToolCalls: Bool
    ) -> StepUpdateResult {
        let required = steps[index].requiredMembers ?? []
        guard let actor = actorName,
              let member = required.first(where: { $0.caseInsensitiveCompare(actor) == .orderedSame }) else {
            return .rejected("This step must be done by each of \(required.joined(separator: ", ")) on their own VM. "
                + "Only they can check in their part; you can't mark it for them.")
        }
        if newStatus != .done {
            if steps[index].status != .done { steps[index].status = newStatus }
            if let evidence, !evidence.isEmpty { steps[index].evidence = evidence }
            return .recorded
        }
        let trimmed = (evidence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minEvidenceLength else {
            return .rejected("Checking in needs evidence (at least \(Self.minEvidenceLength) characters): what you ran or checked and what it showed.")
        }
        guard turnHadToolCalls else { return .recorded }
        var byMember = steps[index].memberEvidence ?? [:]
        let alreadyIn = byMember[member] != nil
        byMember[member] = trimmed
        steps[index].memberEvidence = byMember
        let remaining = steps[index].membersRemaining
        if remaining.isEmpty {
            let wasDone = steps[index].status == .done
            steps[index].status = .done
            steps[index].verified = true
            steps[index].evidence = required.compactMap { name in byMember[name].map { "\(name): \($0)" } }.joined(separator: "\n")
            if !wasDone { messagesSinceProgress = 0; return .progress }
            return .recorded
        }
        steps[index].status = .inProgress
        if !alreadyIn { messagesSinceProgress = 0 }
        return .memberCheckedIn(remaining: remaining)
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

    /// Every step is done (validated); none open or blocked.
    public var allStepsDone: Bool { !steps.isEmpty && steps.allSatisfy { $0.status == .done } }

    /// Closes the goal once every step is done: nothing is left to confirm. A goal with blocked
    /// steps still goes through `proposeComplete` and the user's confirmation. Returns whether it closed.
    @discardableResult
    public mutating func closeIfComplete(summary: String? = nil) -> Bool {
        guard status == .active, allStepsDone else { return false }
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        completionSummary = trimmed.isEmpty ? "All \(steps.count) steps done." : trimmed
        status = .done
        return true
    }

    public mutating func proposeComplete(summary: String, now: Date = Date()) -> StepUpdateResult {
        guard status == .active else { return .rejected("The goal is \(status.rawValue).") }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("A completion summary is required.") }
        let stillOpen = openSteps.filter { $0.status != .blocked }.count
        guard stillOpen == 0 else {
            return .rejected("\(stillOpen) step(s) are still open. Finish them, or mark them blocked with a reason, first.")
        }
        // Everything verified: close it now. Only a partial finish (blocked steps) waits for the user.
        if closeIfComplete(summary: trimmed) { return .recorded }
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
    /// What the goal owner needs to look at (submissions to validate, blocked steps, a finished goal to close),
    /// as an instruction for its review turn, or nil if nothing does.
    public func ownerReviewWork() -> String? {
        var lines: [String] = []
        for (index, step) in steps.enumerated() where step.status == .review && validatorName == nil {
            let evidence = (step.evidence ?? "").prefix(300)
            lines.append("- Waiting for your validation: step \(index + 1) \"\(Self.displayText(step.text))\""
                + (step.assigneeName.map { ", submitted by \($0)" } ?? "") + (evidence.isEmpty ? "" : ". Their evidence: \(evidence)"))
        }
        for (index, step) in steps.enumerated() where step.status == .blocked {
            lines.append("- Blocked: step \(index + 1) \"\(Self.displayText(step.text))\"" + (step.evidence.map { " (\($0.prefix(200)))" } ?? ""))
        }
        if status == .active, allStepsDone {
            lines.append("- Every step is done: call propose_goal_complete with a short summary of the result.")
        }
        guard !lines.isEmpty else { return nil }
        return "GOAL REVIEW (you are the goal owner, and this is your regular check):\n" + lines.joined(separator: "\n")
            + "\nFor each submitted step: get the work onto your VM (git pull, or fetch their branch), run the check yourself, then "
            + "update_goal_step done quoting what YOU saw, or set it back to inProgress with what's missing and @mention the member. "
            + "For a blocked step, choose a way forward or ask the user. If, on checking, nothing needs you, finish silently."
    }

    /// What the validator (when it isn't the owner) needs to check, as an instruction for its review turn.
    public func validatorReviewWork() -> String? {
        guard let validatorName else { return nil }
        let lines = steps.enumerated().filter { $0.element.status == .review }.map { index, step in
            "- Waiting for your validation: step \(index + 1) \"\(Self.displayText(step.text))\""
                + (step.assigneeName.map { ", submitted by \($0)" } ?? "")
                + ((step.evidence ?? "").isEmpty ? "" : ". Their evidence: \((step.evidence ?? "").prefix(300))")
        }
        guard !lines.isEmpty else { return nil }
        return "GOAL REVIEW (you, \(validatorName), validate this goal's submitted work):\n" + lines.joined(separator: "\n")
            + "\nFor each: get the work onto your VM (git fetch, then look at origin/<branch>), run the check yourself, then "
            + "update_goal_step done quoting what YOU saw, or set it back to inProgress with what's missing and @mention the member. "
            + "If, on checking, nothing needs you, finish silently."
    }

    /// Changes whenever a step moves between statuses, so a periodic owner check only repeats when something new
    /// is waiting.
    public var reviewSignature: String {
        steps.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: ",") + ":\(status.rawValue)"
    }

    /// Step text without credentials pasted into URLs (`https://x-access-token:$GITHUB_TOKEN@github.com/...`),
    /// so a plan written that way doesn't keep teaching every member the blocked pattern.
    public static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: #"([a-z][a-z0-9+.-]*://)[^\s/@]*(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|:[^\s/@]+)[^\s/@]*@"#,
                                  with: "$1", options: .regularExpression)
    }

    public func promptBlock(ownerName: String) -> String {
        var lines = ["CURRENT GROUP GOAL (owner: \(ownerName)" + (validatorName.map { ", validated by: \($0)" } ?? "")
            + ", status: \(status.rawValue)): \(title)"]
        for (index, step) in steps.enumerated() {
            let mark: String
            switch step.status {
            case .done: mark = "[x]"
            case .inProgress: mark = "[~]"
            case .blocked: mark = "[!]"
            case .open: mark = "[ ]"
            case .review: mark = "[?]"
            }
            var who = step.assigneeName.map { " (\($0))" } ?? ""
            if let required = step.requiredMembers, !required.isEmpty {
                let remaining = step.membersRemaining
                who = remaining.isEmpty
                    ? " (all \(required.count) checked in)"
                    : " (each member on their own VM: \(required.count - remaining.count)/\(required.count) checked in; waiting on \(remaining.joined(separator: ", ")))"
            }
            let waitingOn = unmetDependencies(of: step.id)
            let waits = step.status != .done && !waitingOn.isEmpty
                ? "  ⏸ WAITING on step \(waitingOn.map { String($0.number) }.joined(separator: ", "))" : ""
            lines.append("  \(index + 1). \(waits.isEmpty ? mark : "[⏸]") \(Self.displayText(step.text))\(who)\(waits)  id=\(step.id)")
        }
        lines.append("Progress: \(doneCount)/\(steps.count) steps done; \(messagesSinceProgress)/\(stallLimit) messages since last verified progress.")
        lines.append("If you're waiting on someone (a review, a push, another step), say so once in your reply and end your turn: "
            + "don't re-check the same files or git log again and again while nothing has changed.")
        if steps.contains(where: isWaiting) {
            lines.append("Steps marked [⏸] can't start until the steps they wait on are done. Don't work on them, and don't write "
                + "stand-ins (stubs, mocks, placeholder files) for what they need. If all your work is waiting, say so in one line "
                + "and stop; or send the member doing the step everyone is waiting on what they need.")
        }
        return lines.joined(separator: "\n")
    }
}


extension Array {
    /// `nil` for an empty array, for optional lists that older saved data leaves out.
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
