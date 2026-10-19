import SwiftUI
import AppKit
import AgentCore

/// One bot's whole settings sheet — identity (name/color/avatar/role) plus
/// what used to live as `DisclosureGroup`s inline in `BotDetailView` (system
/// prompt, skills, permissions, model/budgets), plus its remembered
/// instructions (`BotMemoryStore`). A completely separate sheet from
/// `AppSettingsView`, opened via a specific bot (`.sheet(item:)` in
/// `ContentView`) rather than a tab — see that view's doc comment.
/// Whether a `BotSettingsView` is editing a bot that already exists (the
/// normal case — Done to dismiss, plus the Danger Zone) or is the very
/// first thing shown for a brand-new one before it's actually created
/// (Save actually creates+boots it, Cancel discards the draft entirely —
/// see `ContentView.startNewBotDraft`). A draft bot has no conversation,
/// memory, or sandbox yet, so the Danger Zone has nothing to act on and is
/// hidden rather than shown disabled.
enum BotSettingsMode {
    case edit
    case create(onSave: () -> Void, onCancel: () -> Void)
}

struct BotSettingsView: View {
    @Bindable var bot: Bot
    var mode: BotSettingsMode = .edit
    /// So the "Add routine" form can offer existing groups `bot` is a
    /// member of as a firing target — see `BotSettingsTab`.
    var groupChats: [GroupChatSession] = []
    /// Actually removing the bot needs `ContentView`'s `bots` array — this
    /// sheet only has the one `Bot` it was opened with — so deletion is a
    /// callback out, not something `Bot` or this view can do by itself.
    var onDeleteBot: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteConversationConfirm = false
    @State private var showingDeleteBotConfirm = false
    @State private var showingResetSandboxConfirm = false

    private var closeAction: (() -> Void)? {
        if case .create(_, let onCancel) = mode { return onCancel }
        return nil
    }

    var body: some View {
        SheetScaffold(
            title: bot.name.isEmpty ? "Bot settings" : bot.name,
            subtitle: bot.name.isEmpty ? nil : "Bot settings",
            onClose: closeAction
        ) {
            VStack(alignment: .leading, spacing: 0) {
                BotSettingsTab(bot: bot, groupChats: groupChats)

                if case .edit = mode {
                    SettingsGroupHeader(title: "Danger zone", symbol: "exclamationmark.triangle", detail: "Can't be undone")
                    CollapsibleSection("Delete or reset", summary: "Conversation, VM, bot", symbol: "trash", storageKey: "bot.dangerZone") {
                    Card {
                        Button { showingDeleteConversationConfirm = true } label: {
                            SettingRow("Delete conversation…", titleColor: Theme.destructive)
                        }
                        .buttonStyle(.plain)
                        .disabled(bot.isBusy || bot.displayMessages.isEmpty)
                        .opacity(bot.isBusy || bot.displayMessages.isEmpty ? 0.4 : 1)

                        CardDivider()

                        Button { showingResetSandboxConfirm = true } label: {
                            SettingRow("Reset sandbox…", subtitle: "Destroy this bot's Linux VM and boot a fresh one.", titleColor: Theme.destructive)
                        }
                        .buttonStyle(.plain)
                        .disabled(bot.handle == nil)
                        .opacity(bot.handle == nil ? 0.4 : 1)
                        .help("Destroy this bot's Linux VM and boot a fresh one — use if it may be compromised.")

                        CardDivider()

                        Button { showingDeleteBotConfirm = true } label: {
                            SettingRow("Delete bot…", titleColor: Theme.destructive)
                        }
                        .buttonStyle(.plain)
                        .disabled(bot.isBusy)
                        .opacity(bot.isBusy ? 0.4 : 1)
                    }
                    }
                }
            }
        } footer: {
            SheetFooter {
                switch mode {
                case .edit:
                    Button("Done") { dismiss() }
                        .buttonStyle(.primaryPill)
                        .keyboardShortcut(.defaultAction)
                case .create(let onSave, let onCancel):
                    Button("Cancel", role: .cancel) { onCancel() }
                    Button("Save") { onSave() }
                        .buttonStyle(.primaryPill)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 560, height: 700)
        // The system color panel is its own floating window; it would otherwise
        // stay on screen after this sheet is closed (Done, Cancel or Save).
        .onDisappear { NSColorPanel.shared.close() }
        .alert("Delete this conversation?", isPresented: $showingDeleteConversationConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { bot.clearConversation() }
        } message: {
            Text("\(bot.name)'s transcript is permanently deleted. Its settings, memory, and routines are unaffected, and its sandbox keeps running.")
        }
        .alert("Reset \(bot.name)'s sandbox?", isPresented: $showingResetSandboxConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset, keep files") { Task { await bot.resetSandbox(wipeWorkspace: false) } }
            Button("Reset and wipe files", role: .destructive) { Task { await bot.resetSandbox(wipeWorkspace: true) } }
        } message: {
            Text("Stops any running work, destroys the Linux VM, and boots a fresh one from the image. Installed tools, /home/box and the browser profile are lost. Files in /workspace are kept unless you choose to wipe them. The chat history is kept.")
        }
        .alert("Delete \(bot.name)?", isPresented: $showingDeleteBotConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDeleteBot()
                dismiss()
            }
        } message: {
            Text("Removes \(bot.name) from the sidebar and permanently deletes its conversation, memory, routines, "
                + "and its Linux sandbox container. This cannot be undone.")
        }
    }
}

/// The actual per-bot settings content, factored out of `BotSettingsView`
/// only so its `ScrollView` isn't fighting the sheet's own Done-button
/// footer for vertical space.
private enum RoutineScheduleKind: String, CaseIterable, Identifiable {
    case once, daily, interval
    var id: String { rawValue }
    var label: String {
        switch self {
        case .once: return "Once"
        case .daily: return "Daily"
        case .interval: return "Every N minutes"
        }
    }
}

struct BotSettingsTab: View {
    @Bindable var bot: Bot
    /// Groups `bot` is currently a member of — so "Add routine" can offer
    /// firing into one of them instead of `bot`'s own chat. Not every
    /// group that exists: targeting one `bot` isn't in would just fail
    /// silently at fire time (see `GroupChatSession.fireRoutine`'s
    /// membership guard), so it's not offered as an option at all.
    var groupChats: [GroupChatSession] = []
    @State private var newMemoryText = ""
    @State private var tidyNote: String?
    @State private var memoryFilter = "all"
    @State private var newTaskText = ""

    @State private var newRoutineInstruction = ""
    @State private var newRoutineScheduleKind: RoutineScheduleKind = .daily
    @State private var newRoutineOnceDate = Date().addingTimeInterval(3600)
    @State private var newRoutineDailyTime = Date()
    @State private var newRoutineIntervalMinutes = 30
    /// `nil` = fires in `bot`'s own chat, matching `Routine.targetGroupID`.
    @State private var newRoutineTargetGroupID: String?
    /// Set when `addRoutine()`'s save fails — otherwise this UI just
    /// showed the routine in the list (it's already live in-memory,
    /// its timer already scheduled) with zero indication the disk
    /// write behind it silently failed, the same truthfulness gap the
    /// `create_routine` TOOL path was fixed for already.
    @State private var routineSaveError: String?
    /// Non-nil while the "Add routine" form below is actually editing an
    /// existing routine (populated from it by the row's pencil button)
    /// instead of building a new one.
    @State private var editingRoutineID: String?

    private var eligibleGroups: [GroupChatSession] {
        groupChats.filter { $0.memberBotIDs.contains(bot.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identitySection


                SettingsGroupHeader(title: "Behavior", symbol: "text.bubble", detail: "What this bot is told, what it knows how to do, and how it runs a goal")
                ExpandableCard("Custom instructions", summary: bot.systemPromptText.isEmpty ? "None" : "Set", symbol: "text.quote") {
                    Text("Optional. Added to the built-in behavior (tools, how tasks finish, verification), which every bot always has and which can't be edited here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $bot.systemPromptText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(height: 120)
                        .themedEditor()
                }
                .help(bot.isBusy ? "A run already going keeps the old instructions; the next one uses these." : "")

                ExpandableCard("Skills", summary: "\(bot.selectedSkillIDs.count) of \(bot.availableSkills.count)", symbol: "book.closed") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(
                                get: { bot.selectedSkillIDs.count == bot.availableSkills.count && !bot.availableSkills.isEmpty },
                                set: { selectAll in
                                    bot.selectedSkillIDs = selectAll ? Set(bot.availableSkills.map(\.id)) : []
                                }
                            )) {
                                Text("Select all").font(.system(size: 14, weight: .semibold))
                            }
                            .toggleStyle(.switch)
                            .tint(Theme.positive)
                            .disabled(bot.availableSkills.isEmpty)

                            Divider().overlay(Theme.hairline)

                            ForEach(bot.availableSkills) { skill in
                                Toggle(isOn: Binding(
                                    get: { bot.selectedSkillIDs.contains(skill.id) },
                                    set: { isOn in
                                        if isOn { bot.selectedSkillIDs.insert(skill.id) }
                                        else { bot.selectedSkillIDs.remove(skill.id) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(skill.name).font(.system(size: 14))
                                        if !skill.description.isEmpty {
                                            Text(skill.description)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .tint(Theme.positive)

                            }
                        }
                    }
                    .frame(height: 200)
                }
                .help(bot.isBusy ? "A run already going keeps its skills; the next one uses these." : "")
                .padding(.top, 12)

                Card {
                    ToggleRow(title: "Checks submitted work itself",
                              subtitle: "When this bot owns a group goal, it re-runs members' checks before marking steps done. Turn off for a manager that only coordinates: another member validates, and in goal turns this bot gets no file, shell or desktop tools, so it assigns and unblocks instead of doing the work.",
                              isOn: $bot.checksGoalWorkItself)
                }
                .padding(.top, 10)

                SettingsGroupHeader(title: "Model", symbol: "cpu", detail: "Which model answers, a fallback for when it can't be reached, and run limits")
                CollapsibleSection("Main model, fallback and limits", summary: bot.selectedModel.isEmpty ? "Not chosen" : bot.selectedModel, symbol: "slider.horizontal.3", storageKey: "bot.model") {
                Card {
                    PickerRow(
                        title: "Provider",
                        selection: $bot.modelProvider,
                        options: [(ModelProvider.ollama, "Local (Ollama)"), (ModelProvider.remote, "Remote (OpenAI-compatible)")]
                    )
                    .disabled(bot.isBusy)
                    .help(bot.isBusy ? "Locked while this bot is working — change it once it's idle. The conversation carries over." : "")

                    CardDivider()

                    PickerRow(
                        title: "Engine",
                        subtitle: bot.engine == .smolagents
                            ? "Experimental. Runs this bot's own chat with smolagents inside its sandbox (local Ollama models only). Set up under Settings › Agent engine."
                            : nil,
                        selection: $bot.engine,
                        options: AgentEngineKind.allCases.map { ($0, $0.label) }
                    )
                    .disabled(bot.isBusy)

                    CardDivider()

                    if bot.modelProvider == .ollama {
                        SettingRow("Model") {
                            Picker("Model", selection: $bot.selectedModel) {
                                ForEach(bot.availableModels, id: \.self) { model in
                                    Text(model).lineLimit(1).truncationMode(.middle).tag(model)
                                }
                                // A saved model that isn't in the list (not pulled yet, or the list is still loading)
                                // must still be a choice, or the picker shows nothing selected.
                                if !bot.selectedModel.isEmpty, !bot.availableModels.contains(bot.selectedModel) {
                                    Text("\(bot.selectedModel) (not installed)").lineLimit(1).truncationMode(.middle).tag(bot.selectedModel)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 380, alignment: .trailing)
                            .disabled(bot.isBusy || bot.availableModels.isEmpty)
                            .help(bot.isBusy ? "Locked while this bot is working — change it once it's idle. The conversation carries over." : "")
                        }
                        .task(id: bot.modelProvider) { await bot.loadLocalModelsIfNeeded() }
                        CardDivider()
                        ToggleRow(title: "Vision", subtitle: "Whether this model can see screenshots. Ollama doesn't advertise this, so it's manual.", isOn: $bot.modelHasVision)
                            .disabled(bot.isBusy)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("Presets").font(.caption).foregroundStyle(.secondary)
                                Button("Google Gemini") {
                                    bot.remoteBaseURLText = OpenAICompatibleBackend.geminiBaseURL
                                    if bot.selectedModel.isEmpty || !bot.selectedModel.lowercased().hasPrefix("gemini") { bot.selectedModel = "gemini-3.8-flash" }
                                    bot.modelHasVision = true
                                }
                                .help("Gemini through Google's OpenAI-compatible endpoint. Paste a Gemini API key below; it goes to the Keychain.")
                                Button("OpenAI") {
                                    bot.remoteBaseURLText = "https://api.openai.com/v1"
                                }
                                Spacer()
                            }
                            .disabled(bot.isBusy)
                            TextField("Base URL (e.g. https://api.openai.com/v1)", text: $bot.remoteBaseURLText)
                                .themedField()
                                .disabled(bot.isBusy)
                            TextField("Model id (e.g. gpt-4o)", text: $bot.selectedModel)
                                .themedField()
                                .disabled(bot.isBusy)
                            SecureField("API key (leave blank to keep the saved one)", text: $bot.remoteAPIKeyInput)
                                .themedField()
                                .disabled(bot.isBusy)
                                .help("Stored in the Keychain, never in bots.json — typing a new value here replaces the saved one when you close this sheet.")
                        }
                        .padding(16)
                        CardDivider()
                        ToggleRow(title: "Vision", subtitle: "Whether this model can see screenshots — no reliable way to detect this across providers, so it's manual.", isOn: $bot.modelHasVision)
                            .disabled(bot.isBusy)
                    }

                    CardDivider()

                    PickerRow(
                        title: "Fallback model",
                        subtitle: "Used when the main model can't be reached after a few tries (no connection, timeouts, server errors, rate limits). The bot switches back on its own a few minutes later.",
                        selection: Binding(get: { bot.fallbackProvider }, set: { bot.fallbackProvider = $0 }),
                        options: [(nil as ModelProvider?, "None"), (ModelProvider.ollama, "Local (Ollama)"), (ModelProvider.remote, "Remote (OpenAI-compatible)")]
                    )
                    .disabled(bot.isBusy)
                    if let fallbackProvider = bot.fallbackProvider {
                        CardDivider()
                        VStack(alignment: .leading, spacing: 10) {
                            if fallbackProvider == .ollama {
                                if bot.availableModels.isEmpty {
                                    Text("No local models found. Is Ollama running?").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Picker("Model", selection: $bot.fallbackModel) {
                                        Text("Choose…").tag("")
                                        // A model typed in for a remote fallback before switching to local stays selectable.
                                        if !bot.fallbackModel.isEmpty, !bot.availableModels.contains(bot.fallbackModel) {
                                            Text(bot.fallbackModel).tag(bot.fallbackModel)
                                        }
                                        ForEach(bot.availableModels, id: \.self) { model in Text(model).tag(model) }
                                    }
                                    .pickerStyle(.menu)
                                    .fixedSize()
                                }
                            } else {
                                HStack(spacing: 8) {
                                    Text("Presets").font(.caption).foregroundStyle(.secondary)
                                    Button("Google Gemini") {
                                        bot.fallbackBaseURLText = OpenAICompatibleBackend.geminiBaseURL
                                        if !bot.fallbackModel.lowercased().hasPrefix("gemini") { bot.fallbackModel = "gemini-3.8-flash" }
                                    }
                                    Button("OpenAI") { bot.fallbackBaseURLText = "https://api.openai.com/v1" }
                                    Spacer()
                                }
                                TextField("Base URL (e.g. https://api.openai.com/v1)", text: $bot.fallbackBaseURLText)
                                    .themedField()
                                TextField("Model id", text: $bot.fallbackModel)
                                    .themedField()
                                SecureField("API key (leave blank to keep the saved one)", text: $bot.fallbackAPIKeyInput)
                                    .themedField()
                                    .help("Stored in the Keychain, never in bots.json.")
                            }
                            Toggle("Fallback model has vision", isOn: $bot.fallbackHasVision)
                                .toggleStyle(.switch).tint(Theme.positive)
                        }
                        .padding(16)
                        .disabled(bot.isBusy)
                        .task(id: fallbackProvider) { if fallbackProvider == .ollama { await bot.loadLocalModelsIfNeeded() } }
                    }

                    CardDivider()

                    SettingRow("Max tokens") {
                        TokenLimitField(text: $bot.maxTokensText, width: 110)
                    }
                    CardDivider()
                    SettingRow("Max iterations") {
                        TextField("40", text: $bot.maxIterationsText)
                            .themedField()
                            .frame(width: 110)
                    }
                }
                .help(bot.isBusy
                    ? "A run already going keeps its limits; the next one uses these."
                    : "Raise this if you've selected several skills — the whole system prompt resends every turn, "
                    + "so a large one burns through the token budget in a handful of turns.")
                }

                SettingsGroupHeader(title: "Computer", symbol: "desktopcomputer", detail: "This bot's own Linux VM, and what it may run there without asking")
                Card {
                    SettingRow(
                        bot.handle.map { "shellhouse-vm-\($0.id)" } ?? "Not running",
                        subtitle: "This bot's own private Linux VM. Its files and installed packages are not visible to any other bot."
                    ) {
                        Image(systemName: "desktopcomputer").foregroundStyle(bot.sandbox == nil ? Color.secondary : Theme.positive)
                    }
                }

                ExpandableCard("Shell permissions", summary: "\(bot.sessionAllowedBinaries.count) session · \(bot.globalAllowedBinaries.count) always · \(bot.blanketShellScopes.count) all-shell", symbol: "lock.shield") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(bot.blanketShellScopes, id: \.self) { scope in
                            HStack {
                                Text("ALL shell commands").font(.system(size: 13, design: .monospaced))
                                Text(blanketBadge(scope))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.warning)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Theme.warning.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Spacer()
                                Button("Revoke") { Task { await bot.revokeAllShell(scope: scope) } }
                                    .buttonStyle(.compactPill)
                            }
                        }
                        if bot.sessionAllowedBinaries.isEmpty && bot.globalAllowedBinaries.isEmpty && bot.blanketShellScopes.isEmpty {
                            Text("Nothing always-allowed yet — approve a run_shell command and choose "
                                + "\"Always allow…\" to add one.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(bot.sessionAllowedBinaries, id: \.self) { binary in
                            permissionRow(binary, scope: .session, badge: "session")
                        }
                        ForEach(bot.globalAllowedBinaries, id: \.self) { binary in
                            permissionRow(binary, scope: .global, badge: "always")
                        }
                    }
                }
                .task { await bot.refreshPermissions() }
                .padding(.top, 12)


                SettingsGroupHeader(title: "Memory and work", symbol: "brain", detail: "What it remembers, what it's tracking, and what it does on a schedule")
                ExpandableCard("Memory", summary: "\(bot.memories.count) notes", symbol: "brain") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes this bot keeps — from its own `remember` tool during a "
                            + "conversation, or added here by hand. Pinned and high-importance notes go in every prompt; "
                            + "the rest appear when relevant to a message.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if !bot.memories.isEmpty {
                            let model = ModelTiers.embeddingModel
                            Text(model.isEmpty
                                 ? "Search is by keywords. Pick an embedding model in Settings › Memory embeddings to also search by meaning."
                                 : "\(bot.memoriesIndexed) of \(bot.memories.count) notes indexed for meaning (\(model)).")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        if bot.memories.isEmpty {
                            Text("Nothing remembered yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Picker("Show", selection: $memoryFilter) {
                            Text("All").tag("all")
                            Text("Unverified").tag("untrusted")
                            Text("Stale").tag("stale")
                            ForEach(Array(Set(bot.memoryBook.entries.map(\.source))).sorted(), id: \.self) { Text("From \($0)").tag("source:\($0)") }
                        }
                        .pickerStyle(.menu).fixedSize()
                        ForEach(Array(bot.memoryBook.entries.enumerated()).filter { memoryMatchesFilter($0.element) }, id: \.element.id) { index, entry in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    bot.setMemoryPinned(index, !entry.pinned)
                                } label: {
                                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(entry.pinned ? Theme.accent : .secondary)
                                .help(entry.pinned ? "Pinned: always in this bot's core notes" : "Pin: always include in this bot's core notes")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text).font(.system(size: 14)).textSelection(.enabled)
                                        .opacity(entry.stale ? 0.55 : 1)
                                    Text("importance \(String(repeating: "●", count: entry.importance))\(String(repeating: "○", count: 5 - entry.importance))"
                                        + (entry.useCount > 0 ? " · used \(entry.useCount)×" : "") + " · \(entry.source)"
                                        + (entry.trust == .untrusted ? " · unverified" : "") + (entry.stale ? " · stale" : "")
                                        + " · \(MemoryPrompt.age(of: entry.createdAt))")
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if entry.trust == .untrusted {
                                    Button("Trust") { bot.reviewMemory(index) }
                                        .buttonStyle(.borderless).font(.system(size: 11))
                                        .help("You've read this note and vouch for it: it becomes a note from you and can be pinned")
                                }
                                Button(entry.stale ? "Not stale" : "Stale") { bot.setMemoryStale(index, !entry.stale) }
                                    .buttonStyle(.borderless).font(.system(size: 11))
                                    .help(entry.stale ? "Use this note normally again" : "This note is out of date: keep it, but out of the core prompt")
                                Menu {
                                    ForEach((1...5).reversed(), id: \.self) { level in
                                        Button("Importance \(level)") { bot.setMemoryImportance(index, level) }
                                    }
                                } label: { Image(systemName: "slider.horizontal.3") }
                                    .menuStyle(.borderlessButton).fixedSize().help("Set how important this note is")
                                Button {
                                    bot.removeMemory(at: IndexSet(integer: index))
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            TextField("Add an instruction…", text: $newMemoryText)
                                .themedField()
                                .onSubmit { addMemory() }
                            Button("Add") { addMemory() }
                                .disabled(newMemoryText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        HStack {
                            Button("Tidy up") {
                                let report = bot.consolidateMemories(force: true)
                                tidyNote = report.isEmpty ? "Nothing to tidy."
                                    : "Merged \(report.merged.count) near-duplicate\(report.merged.count == 1 ? "" : "s"), archived \(report.archived.count) stale note\(report.archived.count == 1 ? "" : "s")."
                            }
                            .help("Merge near-duplicate notes and archive old, never-used, low-importance ones. Nothing is deleted outright.")
                            if let tidyNote { Text(tidyNote).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.top, 12)

                ExpandableCard("Tasks", summary: "\(bot.tasks.count) open", symbol: "checklist") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One-shot tasks this bot is carrying — from its own remember_task tool, or added "
                            + "here by hand. Unlike Memory, these are meant to be removed once done: this bot's "
                            + "own complete_task tool clears them, or remove one yourself below. They follow "
                            + "it into a group turn or a delegation, which otherwise have no access to this "
                            + "chat's history.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if bot.tasks.isEmpty {
                            Text("Nothing in progress.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(bot.tasks.enumerated()), id: \.offset) { index, task in
                            HStack(alignment: .top) {
                                Text(task.text).font(.system(size: 14)).textSelection(.enabled)
                                Spacer()
                                Button {
                                    bot.removeTask(at: IndexSet(integer: index))
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            TextField("Add a task…", text: $newTaskText)
                                .themedField()
                                .onSubmit { addTask() }
                            Button("Add") { addTask() }
                                .disabled(newTaskText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(.top, 12)

                ExpandableCard("Routines", summary: "\(bot.routines.count)", symbol: "clock.arrow.circlepath") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Time-based triggers that queue a message to this bot on their own — added here, "
                            + "or by the bot itself via its create_routine tool. A routine can post into a "
                            + "group chat instead of this one, if this bot is already a member of one.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if bot.routines.isEmpty {
                            Text("No routines yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(bot.routines.enumerated()), id: \.offset) { index, routine in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(routine.schedule.summary).font(.system(size: 14, weight: .semibold))
                                        if let groupID = routine.targetGroupID {
                                            Text("→ \(groupChats.first { $0.id == groupID }?.name ?? "deleted group")")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .background(Theme.chip, in: Capsule())
                                        }
                                    }
                                    Text(routine.instruction)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    bot.runRoutineNow(id: routine.id)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Run now (doesn't change its schedule)")
                                .disabled(bot.sandbox == nil)
                                Button {
                                    beginEditingRoutine(routine)
                                } label: {
                                    Image(systemName: "pencil.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                Button {
                                    if editingRoutineID == routine.id { cancelEditingRoutine() }
                                    bot.removeRoutine(at: IndexSet(integer: index))
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(
                                editingRoutineID == routine.id ? Theme.accent.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }

                        Divider().overlay(Theme.hairline)

                        if editingRoutineID != nil {
                            Text("Editing routine").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        }

                        TextField("What should it do when it fires?", text: $newRoutineInstruction)
                            .themedField()

                        Picker("Schedule", selection: $newRoutineScheduleKind) {
                            ForEach(RoutineScheduleKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch newRoutineScheduleKind {
                        case .once:
                            DatePicker(
                                "At", selection: $newRoutineOnceDate, in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        case .daily:
                            DatePicker("At", selection: $newRoutineDailyTime, displayedComponents: [.hourAndMinute])
                        case .interval:
                            HStack {
                                Text("Every")
                                TextField("30", value: $newRoutineIntervalMinutes, format: .number)
                                    .themedField()
                                    .frame(width: 70)
                                Text("minutes")
                            }
                        }

                        if !eligibleGroups.isEmpty {
                            Picker("Post in", selection: $newRoutineTargetGroupID) {
                                Text("This chat").tag(String?.none)
                                ForEach(eligibleGroups) { group in
                                    Text(group.name).tag(String?.some(group.id))
                                }
                            }
                        }

                        HStack {
                            Button(editingRoutineID != nil ? "Save changes" : "Add routine") {
                                if editingRoutineID != nil {
                                    saveRoutineEdit()
                                } else {
                                    addRoutine()
                                }
                            }
                            .buttonStyle(.primaryPill)
                            .disabled(newRoutineInstruction.trimmingCharacters(in: .whitespaces).isEmpty)

                            if editingRoutineID != nil {
                                Button("Cancel") { cancelEditingRoutine() }
                            }
                        }
                    }
                }

            }
            .padding(.bottom, 8)
        }
        .alert("Routine not saved", isPresented: Binding(
            get: { routineSaveError != nil },
            set: { if !$0 { routineSaveError = nil } }
        )) {
            Button("OK", role: .cancel) { routineSaveError = nil }
        } message: {
            Text(routineSaveError ?? "")
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Identity", symbol: "person.crop.circle", detail: "How this bot appears in the sidebar and in chats")
            BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 96)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 12)

            Card {
                SettingRow("Name") {
                    TextField("Name", text: $bot.name)
                        .themedField()
                        .frame(width: 280)
                }
                CardDivider()
                SettingRow("Role") {
                    TextField("e.g. \"UI Expert\"", text: $bot.tagline)
                        .themedField()
                        .frame(width: 280)
                }
                CardDivider()
                SettingRow("Group") {
                    TextField("e.g. \"General\"", text: $bot.group)
                        .themedField()
                        .frame(width: 280)
                }
                CardDivider()
                SettingRow("Color") {
                    HStack(spacing: 8) {
                        ForEach(botColorPalette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(.primary, lineWidth: bot.colorHex.uppercased() == hex.uppercased() ? 2 : 0))
                                .onTapGesture { bot.colorHex = hex }
                        }
                        ColorPicker("Custom", selection: Binding(
                            get: { Color(hex: bot.colorHex) },
                            set: { bot.colorHex = $0.toHex() }
                        ))
                        .labelsHidden()
                    }
                }
            }

            CollapsibleSection("Avatar shape", summary: AvatarStyle(rawValue: bot.avatarStyle)?.label, symbol: "face.smiling", storageKey: "bot.avatarShape") {
                Card {
                    AvatarPicker(colorHex: bot.colorHex, selection: $bot.avatarStyle)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func blanketBadge(_ scope: RunShellPermissions.BlanketScope) -> String {
        switch scope {
        case .botSession: return "this bot, session"
        case .botAlways: return "this bot, always"
        case .everyBot: return "every bot"
        }
    }

    @ViewBuilder
    private func permissionRow(_ binary: String, scope: RunShellPermissions.Scope, badge: String) -> some View {
        HStack {
            Text(binary).font(.system(size: 13, design: .monospaced))
            Text(badge)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer()
            Button("Revoke") {
                Task { await bot.revokePermission(binary, scope: scope) }
            }
            .buttonStyle(.compactPill)
        }
    }

    private func memoryMatchesFilter(_ entry: MemoryEntry) -> Bool {
        switch memoryFilter {
        case "untrusted": return entry.trust == .untrusted
        case "stale": return entry.stale
        case let f where f.hasPrefix("source:"): return entry.source == String(f.dropFirst(7))
        default: return true
        }
    }

    private func addMemory() {
        bot.addMemory(newMemoryText, source: "user")
        newMemoryText = ""
    }

    private func addTask() {
        bot.addTask(newTaskText)
        newTaskText = ""
    }

    private func addRoutine() {
        let instruction = newRoutineInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        let schedule: Routine.Schedule
        switch newRoutineScheduleKind {
        case .once:
            schedule = .once(newRoutineOnceDate)
        case .daily:
            let components = Calendar.current.dateComponents([.hour, .minute], from: newRoutineDailyTime)
            schedule = .daily(hour: components.hour ?? 9, minute: components.minute ?? 0)
        case .interval:
            schedule = .interval(minutes: max(1, newRoutineIntervalMinutes))
        }

        let (_, persisted) = bot.addRoutine(instruction: instruction, schedule: schedule, targetGroupID: newRoutineTargetGroupID)
        guard persisted else {
            // Still live in-memory (its timer is already scheduled and
            // WILL fire this session), but that's exactly the trap —
            // it looks like it worked right now, then silently isn't
            // there anymore after the next relaunch. Surface it instead
            // of letting that discovery happen at the routine's actual
            // fire time, days later.
            routineSaveError = "This routine is active for now, but failed to save to disk — it won't "
                + "survive quitting the app. Try adding it again; if this keeps happening, check Console.app "
                + "for a \"[RoutineStore]\" error."
            newRoutineInstruction = ""
            newRoutineTargetGroupID = nil
            return
        }
        newRoutineInstruction = ""
        newRoutineTargetGroupID = nil
    }

    /// Populates the "Add routine" form from an existing routine so its
    /// button turns into "Save changes" instead — reusing the same
    /// fields rather than a separate edit form.
    private func beginEditingRoutine(_ routine: Routine) {
        editingRoutineID = routine.id
        newRoutineInstruction = routine.instruction
        newRoutineTargetGroupID = routine.targetGroupID
        switch routine.schedule {
        case .once(let date):
            newRoutineScheduleKind = .once
            newRoutineOnceDate = date
        case .daily(let hour, let minute):
            newRoutineScheduleKind = .daily
            newRoutineDailyTime = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        case .interval(let minutes):
            newRoutineScheduleKind = .interval
            newRoutineIntervalMinutes = minutes
        }
    }

    private func cancelEditingRoutine() {
        editingRoutineID = nil
        newRoutineInstruction = ""
        newRoutineTargetGroupID = nil
    }

    private func saveRoutineEdit() {
        guard let routineID = editingRoutineID else { return }
        let instruction = newRoutineInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        let schedule: Routine.Schedule
        switch newRoutineScheduleKind {
        case .once:
            schedule = .once(newRoutineOnceDate)
        case .daily:
            let components = Calendar.current.dateComponents([.hour, .minute], from: newRoutineDailyTime)
            schedule = .daily(hour: components.hour ?? 9, minute: components.minute ?? 0)
        case .interval:
            schedule = .interval(minutes: max(1, newRoutineIntervalMinutes))
        }

        let succeeded = bot.updateRoutine(
            id: routineID, instruction: instruction, schedule: schedule, targetGroupID: newRoutineTargetGroupID
        )
        guard succeeded else {
            routineSaveError = "That change couldn't be saved — it may exactly match another routine, or the "
                + "write to disk failed. Try again; if this keeps happening, check Console.app for a "
                + "\"[RoutineStore]\" error."
            return
        }
        cancelEditingRoutine()
    }
}
