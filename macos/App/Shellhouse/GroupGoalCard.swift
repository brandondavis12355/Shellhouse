import SwiftUI
import AgentCore

/// Pinned above a group's transcript while it has a goal (live or just
/// finished): checklist, progress, and the buttons for whatever the user
/// needs to decide right now (confirm completion / continue a stalled goal).
struct GroupGoalCard: View {
    @Bindable var group: GroupChatSession
    let ownerName: String
    /// Shown inside the top-bar popover: always expanded, no collapse chevron, no extra card chrome.
    var inPopover = false
    @State private var expanded = true
    @State private var newStepText = ""
    @State private var feedback = ""

    var body: some View {
        if let goal = group.goal {
            VStack(alignment: .leading, spacing: 8) {
                header(goal)
                ProgressView(value: Double(goal.doneCount), total: Double(max(goal.steps.count, 1)))
                    .tint(statusColor(goal.status))
                if expanded {
                    steps(goal)
                    footer(goal)
                }
            }
            .padding(inPopover ? 0 : 14)
            .background(inPopover ? Color.clear : Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                if !inPopover {
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(statusColor(goal.status).opacity(0.35), lineWidth: 1)
                }
            }
        }
    }

    private func header(_ goal: GroupGoal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(goal.status)).foregroundStyle(statusColor(goal.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.title).font(.subheadline).bold().lineLimit(2)
                Text("\(statusLabel(goal.status)) · owner \(ownerName) · \(goal.doneCount)/\(goal.steps.count) steps · \(goal.messagesSinceProgress)/\(goal.stallLimit) since last progress")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !inPopover {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.plain)
            }
        }
    }

    private func steps(_ goal: GroupGoal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(goal.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: stepIcon(step.status))
                        .foregroundStyle(step.status == .done ? (step.verified ? Color.green : Color.orange) : .secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(index + 1). \(step.text)")
                            .font(.caption)
                            .strikethrough(step.status == .done)
                        if let required = step.requiredMembers, !required.isEmpty {
                            let remaining = step.membersRemaining
                            Text(remaining.isEmpty
                                 ? "all \(required.count) checked in"
                                 : "\(required.count - remaining.count)/\(required.count) checked in · waiting on \(remaining.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if let assignee = step.assigneeName, step.status != .done, step.status != .review {
                            Text(assignee).font(.caption2).foregroundStyle(.secondary)
                        }
                        if step.status == .review {
                            Text("submitted by \(step.assigneeName ?? "a member") — waiting for \(ownerName) to validate")
                                .font(.caption2).foregroundStyle(Theme.warning)
                        }
                        if step.status == .done, !step.verified {
                            Text("done, but unverified (no tool run)").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .help(step.evidence ?? "")
                    Spacer()
                    if goal.isLive {
                        Button { group.removeGoalStep(step.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            if goal.isLive {
                HStack {
                    TextField("Add a step…", text: $newStepText)
                        .themedField().font(.system(size: 13))
                        .onSubmit(addStep)
                    Button("Add", action: addStep).disabled(newStepText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ goal: GroupGoal) -> some View {
        switch goal.status {
        case .awaitingConfirmation:
            VStack(alignment: .leading, spacing: 6) {
                if let summary = goal.completionSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Confirm complete") { group.confirmGoal() }.keyboardShortcut(.defaultAction)
                    TextField("Not yet — what's missing?", text: $feedback)
                        .themedField().font(.system(size: 13))
                        .onSubmit(sendFeedback)
                    Button("Not yet", action: sendFeedback).disabled(feedback.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        case .paused:
            VStack(alignment: .leading, spacing: 6) {
                Text("Paused — no verified progress. \(goal.pauseSummary ?? "")")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Continue") { group.continueGoal() }.keyboardShortcut(.defaultAction)
                    TextField("Redirect — tell them what to do instead", text: $feedback)
                        .themedField().font(.system(size: 13))
                        .onSubmit(sendFeedback)
                    Button("Redirect", action: sendFeedback).disabled(feedback.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Stop", role: .destructive) { group.stopGoal() }
                }
            }
        case .active:
            HStack {
                Spacer()
                Button("Stop goal", role: .destructive) { group.stopGoal() }.font(.caption)
            }
        case .done, .cancelled:
            HStack {
                Spacer()
                Button("Dismiss") { group.clearFinishedGoal() }.font(.caption)
            }
        }
    }

    private func addStep() {
        group.addGoalStep(newStepText)
        newStepText = ""
    }

    private func sendFeedback() {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        feedback = ""
        group.input = text
        group.submitInput()
    }

    private func icon(_ status: GroupGoal.Status) -> String {
        switch status {
        case .active: return "target"
        case .awaitingConfirmation: return "checkmark.seal"
        case .paused: return "pause.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private func statusColor(_ status: GroupGoal.Status) -> Color {
        switch status {
        case .active: return .blue
        case .awaitingConfirmation: return .purple
        case .paused: return .orange
        case .done: return .green
        case .cancelled: return .gray
        }
    }

    private func statusLabel(_ status: GroupGoal.Status) -> String {
        switch status {
        case .active: return "In progress"
        case .awaitingConfirmation: return "Awaiting your confirmation"
        case .paused: return "Paused"
        case .done: return "Done"
        case .cancelled: return "Stopped"
        }
    }

    private func stepIcon(_ status: GroupGoal.StepStatus) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .inProgress: return "circle.dotted"
        case .blocked: return "exclamationmark.triangle.fill"
        case .open: return "circle"
        case .review: return "questionmark.circle"
        }
    }
}
