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
    /// A new sandbox manager token was saved: bots that couldn't start should try again.
    var onManagerTokenChanged: () -> Void = {}
    var onExportSettings: (_ includeSecrets: Bool) -> Void = { _ in }
    var onImportSettings: () -> Void = {}
    @State private var exportIncludesSecrets = false
    @State private var appliedDefaults = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

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
                SettingsGroupHeader(title: "General", symbol: "gearshape", detail: "How the app looks, and what new bots start with")
                Card {
                    PickerRow(
                        title: "Appearance",
                        selection: $appearanceMode,
                        options: [("system", "System"), ("light", "Light"), ("dark", "Night · Black")]
                    )
                }
                CollapsibleSection("Defaults for new bots", summary: "\(defaultMaxIterations) steps · \(defaultMaxTokens) tokens", symbol: "slider.horizontal.3", storageKey: "botDefaults") {
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
                SectionFooter("Used for new bots, and for every bot still on the old default (they follow as you type). Apply to all bots sets every existing bot, including ones you changed. A run already going keeps its limits; the next one uses the new ones.")
                }


                SettingsGroupHeader(title: "Linux host", symbol: "server.rack", detail: "Where every bot's VM runs, and how the app reaches it")
                HostSettingsSection(onChanged: onHostChanged)
                CollapsibleSection("Sandbox manager token", summary: tokenInfo == nil ? "Not set" : "Set", symbol: "key.fill", storageKey: "managerToken") {
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

                CollapsibleSection("Resource stats", symbol: "gauge.with.dots.needle.33percent", storageKey: "resourceStats") {
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

                SettingsGroupHeader(title: "Models", symbol: "cpu", detail: "The local models, and how bots share them")
                OllamaSettingsSection()
                ModelTiersSettingsSection()
                ContextWindowSettingsSection()
                ModelSchedulingSettingsSection()
                AgentEngineSettingsSection()

                SettingsGroupHeader(title: "Safety and accuracy", symbol: "checkmark.shield", detail: "What needs your approval, and the checks that keep bots on track")
                GuardrailSettingsSection()
                AccuracySettingsSection()

                SettingsGroupHeader(title: "Skills", symbol: "book.closed", detail: "Playbooks bots load when a task calls for them")
                SkillsSettingsSection(onChanged: onSkillsChanged)

                SettingsGroupHeader(title: "Advanced", symbol: "wrench.and.screwdriver", detail: "Troubleshooting, and moving settings between Macs")
                Card {
                    ToggleRow(
                        title: "Debug mode",
                        subtitle: "Logs every bot's activity (replies, tool calls and results, approvals, bot-to-bot messages) to the "
                            + "Debug Console window. Open it from Window › Debug Console (⌥⌘D).",
                        isOn: $debugSettings.isEnabled
                    )
                    CardDivider()
                    SettingRow("Debug Console", subtitle: "Filters by kind of entry, bot and conversation") {
                        Button("Open") { openWindow(id: "debug-console") }.buttonStyle(.compactPill)
                    }
                }
                CollapsibleSection("Backup & restore", summary: "Settings file", symbol: "externaldrive", storageKey: "settingsBundle") {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Save every setting (app settings, each bot's settings, each group's settings) to one file, or "
                                + "load one. Importing merges: bots and groups are matched by name and created if missing; "
                                + "conversations and memories are never in the file.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            Toggle("Include secrets (tokens and API keys)", isOn: $exportIncludesSecrets)
                                .toggleStyle(.switch).tint(Theme.positive)
                            if exportIncludesSecrets {
                                Text("The file will hold your tokens and keys in plain text. Keep it somewhere safe and delete it after use.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.warning)
                            }
                            HStack {
                                Button("Export settings…") { onExportSettings(exportIncludesSecrets) }
                                Button("Import settings…") { onImportSettings() }
                            }
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
        .frame(width: 600, height: 760)
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
            RemoteSandboxManager.sharedToken.value = tokenInput
            tokenInput = ""
            tokenStatus = "Saved and in use. Bots that couldn't start are starting again."
            onManagerTokenChanged()
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
