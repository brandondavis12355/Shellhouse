import SwiftUI
import AgentCore

struct AppSettingsView: View {
    @Binding var appearanceMode: String
    @Binding var defaultMaxTokens: String
    @Binding var defaultMaxIterations: String
    var onSkillsChanged: () -> Void = {}
    /// The Linux host's address was saved — bots that couldn't reach the
    /// sandbox before should try again.
    /// Copies the defaults above onto every existing bot.
    var onApplyDefaultsToAllBots: () -> Void = {}
    var onHostChanged: () -> Void = {}
    @State private var appliedDefaults = false
    @Environment(\.dismiss) private var dismiss

    /// A singleton, not a `@Binding` threaded down from `ContentView` —
    /// see `DebugSettings`'s doc comment. `@Bindable` still gives the
    /// `Toggle` below a live two-way binding into it.
    @Bindable private var debugSettings = DebugSettings.shared

    @State private var localStats: MachineStats?
    @State private var remoteStats: MachineStats?
    @State private var isRefreshingStats = false

    @State private var tokenInfo: SecretStore.SecretInfo?
    @State private var tokenInput = ""
    @State private var tokenStatus: String?
    @State private var isSavingToken = false

    var body: some View {
        SheetScaffold(title: "Settings") {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Display")
                Card {
                    PickerRow(
                        title: "Appearance",
                        selection: $appearanceMode,
                        options: [("system", "System"), ("light", "Light"), ("dark", "Night · Black")]
                    )
                }

                GuardrailSettingsSection()

                AccuracySettingsSection()

                ModelTiersSettingsSection()
                ContextWindowSettingsSection()
                ModelSchedulingSettingsSection()

                AgentEngineSettingsSection()

                HostSettingsSection(onChanged: onHostChanged)

                CollapsibleSection("Sandbox manager token", summary: tokenInfo == nil ? "Not set" : "Set", storageKey: "managerToken") {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The shared secret `sandbox-manager` requires on every call (X-Manager-Token). "
                            + "Get the value from MANAGER_TOKEN in the Linux host's .env.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if let tokenInfo {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                                Text("Set — fingerprint \(tokenInfo.fingerprint)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                if let modified = tokenInfo.modified {
                                    Text("· updated \(modified.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                Text("Not set — bots can't reach the sandbox manager until this is added.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            SecureField("New token value", text: $tokenInput)
                                .themedField()
                            Button(tokenInfo == nil ? "Save" : "Rotate") { Task { await saveToken() } }
                                .disabled(tokenInput.isEmpty || isSavingToken)
                            if tokenInfo != nil {
                                Button("Remove", role: .destructive) { Task { await removeToken() } }
                                    .disabled(isSavingToken)
                            }
                        }
                        if let tokenStatus {
                            Text(tokenStatus).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                }

                SectionLabel("Debug")
                Card {
                    ToggleRow(
                        title: "Debug mode",
                        subtitle: "Shows a live console of every bot's raw activity — status changes, tool calls and "
                            + "their results, and the model's own token stream — in a right-hand pane, including "
                            + "from group turns and delegations that are otherwise a black box in the normal chat.",
                        isOn: $debugSettings.isEnabled
                    )
                }

                OllamaSettingsSection()

                SkillsSettingsSection(onChanged: onSkillsChanged)

                CollapsibleSection("Defaults for new bots", summary: "\(defaultMaxIterations) steps · \(defaultMaxTokens) tokens", storageKey: "botDefaults") {
                Card {
                    SettingRow("Max tokens") {
                        TokenLimitField(text: $defaultMaxTokens, width: 120)
                    }
                    CardDivider()
                    SettingRow("Max iterations") {
                        TextField("40", text: $defaultMaxIterations).themedField().frame(width: 120)
                    }
                }
                HStack {
                    Button(appliedDefaults ? "Applied to all bots" : "Apply to all bots") {
                        onApplyDefaultsToAllBots(); appliedDefaults = true
                    }
                    .disabled(appliedDefaults)
                    Spacer()
                }
                .padding(.top, 4)
                .onChange(of: defaultMaxIterations) { appliedDefaults = false }
                .onChange(of: defaultMaxTokens) { appliedDefaults = false }
                SectionFooter("Used for new bots, and for every bot still on the old default when you close Settings. Apply to all bots sets every existing bot, including ones you changed. A run already going keeps its limits; the next one uses the new ones.")
                }

                CollapsibleSection("Resource stats", storageKey: "resourceStats") {
                HStack {
                    Spacer()
                    if isRefreshingStats {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") { Task { await refreshStats() } }
                        .buttonStyle(.compactPill)
                        .disabled(isRefreshingStats)
                        .padding(.trailing, 4)
                }
                Card {
                    HStack(alignment: .top, spacing: 24) {
                        MachineStatsView(title: "This Mac", stats: localStats)
                        MachineStatsView(title: "Linux host (\(RemoteHost.host))", stats: remoteStats)
                    }
                    .padding(16)
                }
                }
            }
        } footer: {
            SheetFooter {
                Button("Done") { dismiss() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 540, height: 700)
        .task {
            await refreshStats()
            await refreshTokenInfo()
        }
    }

    private func refreshStats() async {
        isRefreshingStats = true
        async let local = LocalMachineStats.fetch()
        async let remote = RemoteMachineStats.fetch()
        localStats = await local
        remoteStats = await remote
        isRefreshingStats = false
    }

    private func refreshTokenInfo() async {
        let items = try? await SecretStore().list()
        tokenInfo = items?.first { $0.name == managerTokenName }
    }

    private func saveToken() async {
        isSavingToken = true
        defer { isSavingToken = false }
        do {
            try await SecretStore().put(name: managerTokenName, value: tokenInput)
            tokenInput = ""
            tokenStatus = "Saved. Restart or re-select a bot to pick it up."
            await refreshTokenInfo()
        } catch {
            tokenStatus = error.localizedDescription
        }
    }

    private func removeToken() async {
        isSavingToken = true
        defer { isSavingToken = false }
        do {
            try await SecretStore().delete(name: managerTokenName)
            tokenStatus = "Removed."
            await refreshTokenInfo()
        } catch {
            tokenStatus = error.localizedDescription
        }
    }
}

/// One machine's column in the Resource stats section — load average,
/// memory, and disk, or a short error line if that machine (usually the
/// Linux host, over SSH) couldn't be reached.
private struct MachineStatsView: View {
    let title: String
    let stats: MachineStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let stats {
                if let error = stats.error {
                    Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    if let load = stats.loadAverage1m {
                        row("Load avg", String(format: "%.2f", load) + (stats.coreCount.map { " / \($0) cores" } ?? ""))
                    }
                    if let used = stats.memoryUsedGB, let total = stats.memoryTotalGB {
                        row("Memory", String(format: "%.1f / %.1f GB", used, total))
                    }
                    if let used = stats.diskUsedGB, let total = stats.diskTotalGB {
                        row("Disk", String(format: "%.0f / %.0f GB", used, total))
                    }
                }
            } else {
                Text("Loading…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 13)).monospacedDigit()
        }
    }
}
