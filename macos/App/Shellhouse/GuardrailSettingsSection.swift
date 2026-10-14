import SwiftUI
import AgentCore

/// Guardrail options and a look at the tamper-evident audit log
/// (docs/GUARDRAILS.md). Destructive and credential actions are always gated;
/// the only loosening offered here is the opt-in read-only shell fast path.
struct GuardrailSettingsSection: View {
    @AppStorage("guardrails.autoAllowReadOnlyShell") private var autoAllowReadOnlyShell = false
    @AppStorage("guardrails.yolo") private var yolo = false
    @AppStorage(ActionReviewPrompt.settingKey) private var autoReview = true
    @AppStorage(GuardrailConfig.trustedGitHubOwnersKey) private var trustedOwners = ""
    @State private var confirmingYolo = false
    @State private var entries: [AuditLog.Entry] = []
    @State private var verification: AuditLog.Verification?

    var body: some View {
        CollapsibleSection("Guardrails", summary: yolo ? "YOLO on" : (autoReview ? "Fast-model review on" : "Approvals on"), symbol: "checkmark.shield", storageKey: "guardrails") {
            Card {
                ToggleRow(
                    title: "Let the fast model approve routine actions",
                    subtitle: "Before an action asks you, the bot's fast model checks it against your request. Ordinary work (running and "
                        + "testing code, installs, file changes in the workspace, cloning the repo you asked about) runs on its own; anything "
                        + "that sends data out, publishes, deletes outside the workspace or looks unrelated still asks you, with the reason. "
                        + "Hard blocks, strict approvals (secrets, sudo, typing passwords) and chats with friends always ask. On by default.",
                    isOn: $autoReview
                )
                CardDivider()
                ToggleRow(
                    title: "YOLO mode — don't ask for approval",
                    subtitle: "Bots run everything without a prompt, including after reading web pages or downloads: commands, installs, "
                        + "sudo, deletes, pushes. Still stopped: anything that looks malicious (reading or hunting for keys and credentials, "
                        + "dumping secrets, curl | bash, sending data out after untrusted content, turning off security controls), actions "
                        + "that are dangerous in any run (rm -rf /, reverse shells, miners), and every action in a chat with friends. Everything "
                        + "is written to the audit log. Off by default.",
                    isOn: Binding(
                        get: { yolo },
                        set: { on in if on { confirmingYolo = true } else { yolo = false } }
                    )
                )
                CardDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trusted GitHub owners").font(.system(size: 15, weight: .medium))
                    Text("Your GitHub account or organization, comma-separated. Cloning or pulling their repositories doesn't count as "
                        + "untrusted content, so bots can keep using the GitHub token afterwards. Leave empty to treat every repository as untrusted.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("your-github-name, your-org", text: $trustedOwners)
                        .themedField()
                        .autocorrectionDisabled()
                }
                .padding(16)
                CardDivider()
                ToggleRow(
                    title: "Run provably read-only shell commands without asking",
                    subtitle: "Things like `ls | grep x` or `git status`, only when nothing untrusted has been read. Anything that writes, deletes, "
                        + "uses the network, touches credentials or can't be fully analyzed still asks. Off by default.",
                    isOn: $autoAllowReadOnlyShell
                )
                CardDivider()
                SettingRow(
                    "Audit log",
                    subtitle: verification.map { $0.ok ? "Chain intact · \($0.entries) entries" : "TAMPERING DETECTED — \($0.detail)" }
                        ?? "Every allow, ask, denial and freeze is recorded here (secrets redacted)."
                ) {
                    Button("Verify") { Task { verification = await AuditLog.shared.verify() } }
                        .buttonStyle(.compactPill)
                }
                if !entries.isEmpty {
                    CardDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries.suffix(8).reversed(), id: \.seq) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.outcome)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(color(for: entry.outcome))
                                    .frame(width: 92, alignment: .leading)
                                Text("\(entry.tool): \(entry.preview)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task { entries = await AuditLog.shared.entries(limit: 8) }
        .alert("Turn on YOLO mode?", isPresented: $confirmingYolo) {
            Button("Turn on", role: .destructive) { yolo = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bots will run commands, push code and change their VMs without asking you, even after reading web pages. Only "
                + "actions that look malicious, or are dangerous in any run, still stop for you. You can turn this off at any time.")
        }
    }

    private func color(for outcome: String) -> Color {
        switch outcome {
        case "denied", "tripwire", "run_frozen", "denied_by_user", "approval_expired": return Theme.destructive
        case "quarantined": return Theme.warning
        case "approved", "auto", "granted_binary", "granted_blanket", "yolo_auto", "reviewer_auto": return Theme.positive
        default: return .secondary
        }
    }
}
