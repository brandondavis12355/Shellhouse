import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentCore
import AgentUI

/// Keychain name for the shared secret `sandbox-manager` requires on every
/// call (`X-Manager-Token`). Store it once with:
///
///     try await SecretStore().put(name: "SANDBOX_MANAGER_TOKEN", value: "<MANAGER_TOKEN from the Linux host's .env>")
let managerTokenName = "SANDBOX_MANAGER_TOKEN"

/// Local end of the SSH tunnel (owned by `AppDelegate`'s `SSHTunnel`).
let managerBaseURL = URL(string: "http://127.0.0.1:8765")!

/// A small fixed palette for bot avatars — cycled through as bots are
/// added, matching the reference screenshots' colored-blob-per-bot look
/// without needing a color picker for a first pass.
let botColorPalette = ["#7c3aed", "#0ea5e9", "#22c55e", "#f97316", "#ef4444", "#eab308", "#ec4899", "#14b8a6"]

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Inverse of `init(hex:)`, for round-tripping a `ColorPicker`'s
    /// `Color` back into the `String` `Bot.colorHex` actually stores.
    /// Resolved against `.sRGB` explicitly since a `ColorPicker`'s `Color`
    /// carries no guaranteed color space of its own.
    func toHex() -> String {
        let resolved = self.resolve(in: EnvironmentValues())
        let r = Int((resolved.red * 255).rounded())
        let g = Int((resolved.green * 255).rounded())
        let b = Int((resolved.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// `BotAvatar` (the 8 shapes + their idle animations) and `AvatarPicker`
/// live in `BotAvatar.swift`.

/// The sidebar + detail split: a list of independent `Bot`s (each its own
/// sandbox/model/transcript — see `Bot.swift`), and whichever one is
/// selected rendered by `BotDetailView`. `RunShellPermissions` lives here,
/// not per-bot, since "always allow for this session" is meant to apply
/// across every bot for the life of this app launch.
struct ContentView: View {
    @State private var bots: [Bot] = []
    @State private var groupChats: [GroupChatSession] = []
    /// One selection across both sidebar sections — tagged `"bot:<id>"` or
    /// `"group:<id>"` (see `selectedBot`/`selectedGroup`) since a single
    /// SwiftUI `List` selection binding needs one Hashable type for every
    /// row regardless of which section it's in.
    @State private var selectedItemID: String?
    @State private var runShellPermissions = RunShellPermissions()
    /// One instance, shared by every bot — see `BotDirectory`. `allBots`
    /// is wired to `{ bots }` in `.task` below.
    @State private var botDirectory = BotDirectory()
    /// App-wide settings (appearance, new-bot defaults) — its own sheet,
    /// deliberately separate from `botSettingsTarget` below. They used to
    /// be two tabs of one sheet; kept apart now so "app settings" and "this
    /// bot's settings" are never the same screen even by navigation, not
    /// just visually distinct sections of it.
    @State private var showingAppSettings = false
    /// The bot currently being configured, if any — `.sheet(item:)` rather
    /// than a bool, so opening it always has a specific bot attached and
    /// dismissing it (setting this back to `nil`) is the one signal that
    /// bot's settings sheet actually closed (see the `.onChange` below).
    @State private var botSettingsTarget: Bot?
    /// A brand-new bot's settings, shown before it's actually created —
    /// see `startNewBotDraft`. Separate from `botSettingsTarget` because
    /// the two need different sheet content (Save/Cancel vs. Done, no
    /// Danger Zone) and different `.onChange` behavior (a draft's sheet
    /// closing should never trigger `saveBots()`, since Cancel means the
    /// bot never existed).
    @State private var draftBot: Bot?
    @State private var renamingBot: Bot?
    @State private var renameText = ""
    @State private var pendingDeleteBot: Bot?
    @State private var groupSettingsTarget: GroupChatSession?
    @State private var showingCreateGroup = false
    @State private var pendingDeleteGroup: GroupChatSession?

    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("defaultMaxTokens") private var defaultMaxTokens = "200000"
    @AppStorage("defaultMaxIterations") private var defaultMaxIterations = "40"

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Grouped by `Bot.group` for the sidebar's section headers — "General"
    /// pinned first (it's the default every bot starts in), the rest
    /// alphabetical. Purely a display grouping; see `Bot.group`'s doc
    /// comment for what this deliberately isn't.
    private var groupedBots: [(group: String, bots: [Bot])] {
        Dictionary(grouping: bots, by: \.group)
            .sorted { lhs, rhs in
                if lhs.key == "General" { return true }
                if rhs.key == "General" { return false }
                return lhs.key < rhs.key
            }
            .map { (group: $0.key, bots: $0.value) }
    }

    private var selectedBot: Bot? {
        guard let selectedItemID, selectedItemID.hasPrefix("bot:") else { return nil }
        let botID = String(selectedItemID.dropFirst("bot:".count))
        return bots.first { $0.id == botID }
    }

    private var selectedGroup: GroupChatSession? {
        guard let selectedItemID, selectedItemID.hasPrefix("group:") else { return nil }
        let groupID = String(selectedItemID.dropFirst("group:".count))
        return groupChats.first { $0.id == groupID }
    }

    /// Every bot currently blocked on `requestApproval`'s continuation —
    /// across ALL bots, not just whichever one is selected. `BotDetailView`
    /// only renders `bot.pendingApproval` for the bot it's showing, so
    /// without this, an approval raised mid-delegation or mid-group-chat-
    /// turn (see `Bot.runIsolatedTask`) on a bot you're not currently
    /// looking at would hang silently forever.
    private var botsAwaitingApproval: [Bot] {
        bots.filter { $0.pendingApproval != nil }
    }

    /// The bot the banner should surface, if any — skips whichever bot is
    /// already selected, since its own `ApprovalCard` is already visible
    /// inline in `BotDetailView` and a banner for it would be redundant.
    private var bannerBot: Bot? {
        botsAwaitingApproval.first { $0.id != selectedBot?.id }
    }

    var body: some View {
        // `HSplitView`, not a plain `HStack` — gives the debug pane a
        // user-draggable divider (same mechanism `BotDetailView` uses
        // for its chat/computer split) instead of a fixed width.
        HSplitView {
        NavigationSplitView {
            List(selection: $selectedItemID) {
                ForEach(groupedBots, id: \.group) { section in
                    Section(section.group) {
                        ForEach(section.bots) { bot in
                            BotSidebarRow(bot: bot)
                                .tag("bot:\(bot.id)")
                                .contextMenu {
                                    Button("Rename…") {
                                        renamingBot = bot
                                        renameText = bot.name
                                    }
                                    Button("Bot settings…") { botSettingsTarget = bot }
                                    Divider()
                                    Button("Duplicate…") { duplicateBot(bot) }
                                    Button("Export as template…") { exportBotAsTemplate(bot) }
                                    Divider()
                                    Button("Delete…", role: .destructive) { pendingDeleteBot = bot }
                                }
                        }
                        .onMove { source, destination in
                            moveBots(inSection: section.group, from: source, to: destination)
                        }
                    }
                }
                if !groupChats.isEmpty {
                    Section("Group Chats") {
                        ForEach(groupChats) { group in
                            GroupChatSidebarRow(group: group, allBots: bots)
                                .tag("group:\(group.id)")
                                .contextMenu {
                                    Button("Group settings…") { groupSettingsTarget = group }
                                    Divider()
                                    Button("Delete…", role: .destructive) { pendingDeleteGroup = group }
                                }
                        }
                        .onMove { source, destination in
                            groupChats.move(fromOffsets: source, toOffset: destination)
                            saveGroupChats()
                        }
                    }
                }
            }
            .navigationTitle("Bots")
            // A minimum sized so a row's avatar, name, and role pill are
            // always fully visible — below this, `BotSidebarRow`'s
            // `Text`s would truncate to the point of being useless rather
            // than just looking cramped. `max` keeps it from being dragged
            // so wide it crowds out the chat.
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("New bot…") { startNewBotDraft() }
                        Button("New group chat…") { startNewGroupChat() }
                        Divider()
                        Button("New bot from template…") { importBotTemplate() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .imageScale(.large)
                    .help("Add a bot (its own sandbox), a group chat (up to 6 existing bots), or a bot imported from a template file.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: { showingAppSettings = true }) {
                    HStack {
                        Image(systemName: "gearshape")
                            .imageScale(.large)
                        Text("Settings").font(.system(size: 14))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 12)
            }
        } detail: {
            if let group = selectedGroup {
                GroupChatDetailView(group: group, allBots: bots, onOpenSettings: { groupSettingsTarget = group })
                    .id(group.id)
            } else if let bot = selectedBot {
                BotDetailView(bot: bot, onOpenSettings: { botSettingsTarget = bot }, allBots: bots)
                    // Forces a fresh view identity per bot so `.onAppear`
                    // in `BotDetailView` actually fires on every switch —
                    // without this, SwiftUI treats switching which bot is
                    // shown as an update to the same view rather than a new
                    // one appearing, and the unread-clearing `onAppear`
                    // silently never re-runs after the first bot.
                    .id(bot.id)
            } else {
                VStack(spacing: 8) {
                    Text("No bot selected").font(.title3)
                    Text("Add one with the + button, or pick one from the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Matches `BotDetailView`/`GroupChatDetailView`'s own
                // (lowered) minimum — see their comments on why.
                .frame(minWidth: 560, minHeight: 500)
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $showingAppSettings) {
            AppSettingsView(
                appearanceMode: $appearanceMode,
                defaultMaxTokens: $defaultMaxTokens,
                defaultMaxIterations: $defaultMaxIterations,
                onSkillsChanged: { for bot in bots { bot.refreshAvailableSkills() } }
            )
        }
        .sheet(item: $botSettingsTarget) { bot in
            BotSettingsView(bot: bot, groupChats: groupChats, onDeleteBot: { deleteBotPermanently(bot) })
        }
        // The bot settings sheet is where every persisted per-bot field
        // (name/color/role/system prompt/skills/model/budgets — see
        // `Bot.config`) actually gets edited, so closing it is the one
        // reliable checkpoint to save without wiring a save call into every
        // individual field in `BotSettingsTab`. App-wide settings need no
        // equivalent — they're all plain `@AppStorage`, already persisted
        // the moment each field changes.
        // Keyed by `id` (a plain `String?`, trivially `Equatable`) rather
        // than the `Bot?` binding itself, so this doesn't need `Bot` to
        // conform to `Equatable` just for this one check — `oldID` is the
        // bot that was just being edited, looked back up in `bots` (still
        // there; only deselected from the sheet, not removed) to flush its
        // API key field the same moment its other settings get saved.
        .onChange(of: botSettingsTarget?.id) { oldID, newID in
            guard let oldID, newID == nil else { return }
            saveBots()
            if let bot = bots.first(where: { $0.id == oldID }) {
                Task { await bot.persistRemoteAPIKeyIfChanged() }
            }
        }
        .sheet(item: $draftBot) { bot in
            BotSettingsView(
                bot: bot,
                mode: .create(
                    onSave: { commitDraftBot(bot) },
                    onCancel: { draftBot = nil }
                )
            )
        }
        .alert("Rename bot", isPresented: Binding(
            get: { renamingBot != nil },
            set: { if !$0 { renamingBot = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingBot = nil }
            Button("Save") {
                renamingBot?.name = renameText
                renamingBot = nil
                saveBots()
            }
        }
        .alert("Delete \(pendingDeleteBot?.name ?? "this bot")?", isPresented: Binding(
            get: { pendingDeleteBot != nil },
            set: { if !$0 { pendingDeleteBot = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeleteBot = nil }
            Button("Delete", role: .destructive) {
                if let bot = pendingDeleteBot { deleteBotPermanently(bot) }
                pendingDeleteBot = nil
            }
        } message: {
            Text("Permanently deletes its conversation, memory, routines, and its Linux sandbox container. This cannot be undone.")
        }
        .sheet(item: $groupSettingsTarget) { group in
            GroupChatSettingsView(group: group, allBots: bots, onDelete: { deleteGroupPermanently(group) })
        }
        .onChange(of: groupSettingsTarget == nil) { wasNil, isNil in
            if !wasNil && isNil { saveGroupChats() }
        }
        .sheet(isPresented: $showingCreateGroup) {
            CreateGroupChatView(
                allBots: bots,
                onCreate: { name, memberIDs in
                    let group = GroupChatSession(name: name, memberBotIDs: memberIDs, botDirectory: botDirectory)
                    groupChats.append(group)
                    botDirectory.syncGroups(groupChats)
                    selectedItemID = "group:\(group.id)"
                    saveGroupChats()
                    showingCreateGroup = false
                },
                onCancel: { showingCreateGroup = false }
            )
        }
        .alert("Delete \(pendingDeleteGroup?.name ?? "this group")?", isPresented: Binding(
            get: { pendingDeleteGroup != nil },
            set: { if !$0 { pendingDeleteGroup = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeleteGroup = nil }
            Button("Delete", role: .destructive) {
                if let group = pendingDeleteGroup { deleteGroupPermanently(group) }
                pendingDeleteGroup = nil
            }
        } message: {
            Text("Permanently deletes this group and its shared transcript. The member bots themselves aren't affected.")
        }
        .overlay(alignment: .top) {
            if let bannerBot {
                ApprovalBannerView(
                    bot: bannerBot,
                    extraCount: botsAwaitingApproval.count - 1,
                    onTap: { selectedItemID = "bot:\(bannerBot.id)" }
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bannerBot.id)
            }
        }
        .task {
            // `create_bot`/`add_bot_to_group` tool support — see
            // `BotDirectory`'s doc comments. Same "no confirmation sheet"
            // shape as the first-launch `addBot` bootstrap below: a tool
            // call isn't a place to show a settings sheet, so this commits
            // immediately.
            botDirectory.createBot = { name, tagline in
                let botID = "bot-\(UUID().uuidString.prefix(8))"
                let colorHex = botColorPalette[bots.count % botColorPalette.count]
                let bot = Bot(id: botID, name: name, colorHex: colorHex, tagline: tagline, permissions: runShellPermissions, botDirectory: botDirectory)
                bot.maxTokensText = defaultMaxTokens
                bot.maxIterationsText = defaultMaxIterations
                bots.append(bot)
                botDirectory.sync(bots)
                saveBots()
                Task { await bot.boot() }
                return bot
            }
            botDirectory.addBotToGroup = { bot, groupName in
                guard let group = groupChats.first(where: { $0.name.caseInsensitiveCompare(groupName) == .orderedSame }) else {
                    return false
                }
                let before = group.memberBotIDs.count
                group.addMember(bot)
                guard group.memberBotIDs.count > before else { return false }
                saveGroupChats()
                return true
            }
            let saved = BotStore.load()
            if !saved.isEmpty {
                bots = saved.map { Bot(config: $0, permissions: runShellPermissions, botDirectory: botDirectory) }
                selectedItemID = bots.first.map { "bot:\($0.id)" }
                // `Bot(config:...)` migrates `systemPromptText` down to just the
                // user's own text (see `BuiltInSystemPrompt.userPortion`) — persist that
                // right away rather than leaving it to only ever land on
                // disk if the user happens to touch this bot's Settings
                // sheet later.
                saveBots()
                for bot in bots { Task { await bot.boot() } }
            } else {
                // First launch: recreate the one bot that predates the
                // sidebar ("spike" → the legacy compose-managed container,
                // so anyone upgrading from before this pass reattaches to
                // the same sandbox and its already-seeded /home/box and
                // /workspace, rather than it silently becoming unreachable).
                addBot(id: "spike", name: "Spike")
            }
            // Explicit, synchronous sync rather than a stored closure over
            // `bots` — see `BotDirectory.sync`'s doc comment for why.
            botDirectory.sync(bots)
            groupChats = GroupChatStore.load().map { GroupChatSession(id: $0.id, name: $0.name, memberBotIDs: $0.memberBotIDs, botDirectory: botDirectory, coordinatorBotID: $0.coordinatorBotID, stallLimit: $0.stallLimit, confirmTimeoutMinutes: $0.confirmTimeoutMinutes) }
            botDirectory.syncGroups(groupChats)
            StartupConfigLogger.log(bots: bots, groups: groupChats)
        }
        .onChange(of: DebugSettings.shared.isEnabled) { _, isOn in
            if isOn { StartupConfigLogger.log(bots: bots, groups: groupChats) }
        }
        // A plain sibling of `NavigationSplitView`, not a third column
        // of it or a `.safeAreaInset` on it — `NavigationSplitView`
        // manages its own toolbar/sidebar chrome and safe-area handling
        // internally, and layering another inset on top of that rendered
        // detached from the window instead of docked inside it. A flat
        // sibling has no such interaction: it's an ordinary, fully
        // clipped part of this same window's layout.
        if DebugSettings.shared.isEnabled {
            DebugConsoleView(bots: bots)
                .frame(minWidth: 260, idealWidth: 380, maxWidth: 700)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        }
    }

    private func addBot(id: String? = nil, name: String? = nil) {
        let botID = id ?? "bot-\(UUID().uuidString.prefix(8))"
        let colorHex = botColorPalette[bots.count % botColorPalette.count]
        let bot = Bot(id: botID, name: name ?? "Bot \(bots.count + 1)", colorHex: colorHex, permissions: runShellPermissions, botDirectory: botDirectory)
        bot.maxTokensText = defaultMaxTokens
        bot.maxIterationsText = defaultMaxIterations
        bots.append(bot)
        botDirectory.sync(bots)
        selectedItemID = "bot:\(bot.id)"
        saveBots()
        Task { await bot.boot() }
    }

    private func startNewGroupChat() {
        showingCreateGroup = true
    }

    /// Drag-to-reorder within a sidebar section. Sections are just `bots`
    /// grouped by `Bot.group`, so the new order is written back into the
    /// SAME slots those bots already occupy in `bots` — other sections'
    /// positions are untouched — then saved like any other bot-list change.
    private func moveBots(inSection group: String, from source: IndexSet, to destination: Int) {
        var sectionBots = bots.filter { $0.group == group }
        sectionBots.move(fromOffsets: source, toOffset: destination)
        var reordered = sectionBots.makeIterator()
        bots = bots.map { $0.group == group ? (reordered.next() ?? $0) : $0 }
        botDirectory.sync(bots)
        saveBots()
    }

    private func saveGroupChats() {
        GroupChatStore.save(groupChats.map(\.config))
    }

    private func deleteGroupPermanently(_ group: GroupChatSession) {
        groupChats.removeAll { $0.id == group.id }
        botDirectory.syncGroups(groupChats)
        if selectedItemID == "group:\(group.id)" { selectedItemID = nil }
        group.shutdown()
        group.cancelPendingPersist()
        GroupTranscriptStore.delete(groupID: group.id)
        saveGroupChats()
    }

    /// The toolbar's + button: unlike `addBot` (used for the first-launch
    /// "spike" bootstrap, which should just appear with no prompt), a
    /// user-initiated new bot opens its settings sheet FIRST — in `.create`
    /// mode (Save/Cancel, no Danger Zone) — so name/color/role/etc. are
    /// set up before it's added to the sidebar or booted at all. The `Bot`
    /// object exists in memory the whole time the sheet is open, but
    /// nothing about it touches disk or the network until `commitDraftBot`.
    /// `template` is set for both "New from template…" (import) and
    /// "Duplicate…" — either way this is still a brand-new, unsaved,
    /// unbooted `Bot` that opens the same create-mode settings sheet as a
    /// from-scratch one, so the name/color/etc. can be tweaked before
    /// anything is added to the sidebar or gets its own sandbox.
    private func startNewBotDraft(from template: BotTemplate? = nil) {
        let botID = "bot-\(UUID().uuidString.prefix(8))"
        guard let template else {
            let colorHex = botColorPalette[bots.count % botColorPalette.count]
            let bot = Bot(id: botID, name: "Bot \(bots.count + 1)", colorHex: colorHex, permissions: runShellPermissions, botDirectory: botDirectory)
            bot.maxTokensText = defaultMaxTokens
            bot.maxIterationsText = defaultMaxIterations
            draftBot = bot
            return
        }
        draftBot = Bot(id: botID, template: template, permissions: runShellPermissions, botDirectory: botDirectory)
    }

    private func commitDraftBot(_ bot: Bot) {
        bots.append(bot)
        botDirectory.sync(bots)
        selectedItemID = "bot:\(bot.id)"
        saveBots()
        // A from-scratch draft has none of these; one seeded from a
        // template (import or "Duplicate…") does, and they've only ever
        // existed in memory up to this point — see `Bot.init(id:template:)`.
        if !bot.memories.isEmpty { BotMemoryStore.save(id: bot.id, bot.memories) }
        if !bot.routines.isEmpty { RoutineStore.save(id: bot.id, bot.routines) }
        bot.activateRoutines()
        Task {
            await bot.persistRemoteAPIKeyIfChanged()
            await bot.boot()
        }
        draftBot = nil
    }

    /// "Duplicate…" — same settings/memory/routines as `bot`, minus its
    /// conversation and sandbox, opened in the create-bot sheet so the
    /// copy can be renamed before it's actually added.
    private func duplicateBot(_ bot: Bot) {
        var copy = bot.asTemplate
        copy.name = "\(bot.name) Copy"
        startNewBotDraft(from: copy)
    }

    private func exportBotAsTemplate(_ bot: Bot) {
        let template = bot.asTemplate
        // Build the file BEFORE asking where to save it, so a problem with
        // the bot's data shows up immediately instead of after the panel.
        do {
            _ = try template.encodedXML()
        } catch {
            showExportError("Couldn't build the template for \(bot.name).", error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        let safeName = bot.name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        panel.nameFieldStringValue = "\(safeName)-template.xml"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try template.write(to: url)
            } catch {
                showExportError("Couldn't save the template to \(url.lastPathComponent).", error)
            }
        }
        // Deferred a tick so the context menu that triggered this has fully
        // closed; presenting from inside its action could leave the panel
        // with no window to attach to (silently doing nothing).
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }
    }

    private func showExportError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func importBotTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            do {
                let template = try BotTemplate.load(from: url).sanitizedForImport()
                startNewBotDraft(from: template)
                if !template.routines.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Imported routines are turned off"
                    alert.informativeText = "\(template.routines.count) routine(s) came with this template and were imported disabled. Review their instructions in the new bot's Settings before enabling any of them."
                    alert.runModal()
                }
            } catch {
                showExportError("Couldn't import that template.", error)
            }
        }
    }

    /// Only removes the bot from this sidebar — its sandbox container is
    /// persistent (see `docker_backend.py`) and is deliberately NOT
    /// destroyed here, so re-adding a bot with the same id later reattaches
    /// to the same computer rather than losing it.
    private func removeBot(_ bot: Bot) {
        bots.removeAll { $0.id == bot.id }
        botDirectory.sync(bots)
        if selectedItemID == "bot:\(bot.id)" { selectedItemID = bots.first.map { "bot:\($0.id)" } }
        saveBots()
    }

    /// Unlike `removeBot` (sidebar's "Remove from sidebar," which keeps
    /// everything — including the sandbox — so re-adding the same id
    /// reattaches to it), this is the settings sheet's actual "Delete bot":
    /// it also deletes the transcript/memory/routines files AND tears down
    /// the sandbox container itself (`Bot.destroySandbox`, the one path in
    /// this app that force-destroys a persistent sandbox — see
    /// `docker_backend.py`'s `DockerBackend.destroy`).
    private func deleteBotPermanently(_ bot: Bot) {
        // Otherwise an in-flight `drainTask` (this bot's own chat still
        // processing a message) keeps the `Bot` instance alive via its
        // own strong `self` capture even after it's gone from `bots`/
        // `botDirectory` — and when that run finishes, it calls
        // `persistTranscript`/`RoutineStore.save` etc., RECREATING the
        // files this function is about to delete, as if the bot were
        // still there. `stop()` doesn't guarantee an already-executing
        // tool call halts instantly, but it does stop the drain loop
        // from starting anything new and cancels the current run at its
        // next cooperative checkpoint. Any pending routine `Timer` gets
        // the same treatment — no reason for one to fire into a bot
        // that no longer exists.
        bot.stop()
        bot.invalidateAllRoutineTimers()
        removeBot(bot)
        // Otherwise a deleted bot permanently occupies a membership slot —
        // `GroupChatSession.addMember`'s cap check counts `memberBotIDs`
        // by raw id, with no way to tell a real member from a dangling
        // one, so a 6-member group missing this one bot would refuse new
        // members forever with a misleading "already at the cap" error.
        for group in groupChats {
            group.removeMember(bot.id)
        }
        saveGroupChats()
        bot.cancelPendingTranscriptSave()
        TranscriptStore.delete(id: bot.id)
        BotMemoryStore.delete(id: bot.id)
        RoutineStore.delete(id: bot.id)
        ContextSummaryStore.delete(id: bot.id)
        BotTaskStore.delete(id: bot.id)
        Task { await bot.destroySandbox() }
    }

    private func saveBots() {
        BotStore.save(bots.map(\.config))
    }
}

/// App-wide settings — appearance and new-bot defaults. Nothing here is
/// specific to any one bot; that's `BotSettingsView`, a completely separate
/// sheet (see `ContentView`'s `showingAppSettings` vs. `botSettingsTarget`)
/// rather than another tab of this one, so the two are never reachable from
/// the same screen. Deliberately small and honest: every control here
/// actually does something (appearance really changes
/// `.preferredColorScheme`; the budget defaults really seed new bots'
/// fields) rather than padding this out with inert toggles.
/// One sidebar row — factored out of `ContentView`'s `body` because the
/// combined avatar/name/role-pill/preview layout, inlined into that
/// already-large `body`, pushed the compiler's type-checker over its time
/// budget (a real "unable to type-check this expression" error, not a
/// style preference).
private struct BotSidebarRow: View {
    let bot: Bot

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(bot.name)
                        .font(.system(size: 17))
                        .fontWeight(bot.hasUnread ? .semibold : .regular)
                    if !bot.tagline.isEmpty {
                        Text(bot.tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(hex: bot.colorHex).opacity(0.18), in: Capsule())
                    }
                }
                if let preview = bot.lastMessagePreview {
                    // Unread reads brighter and bolder — same "you haven't
                    // looked at this yet" language as Messages on iPhone —
                    // and fades back to a plain secondary preview the
                    // instant `BotDetailView` marks it read.
                    Text(preview)
                        .font(.subheadline)
                        .fontWeight(bot.hasUnread ? .semibold : .regular)
                        .foregroundStyle(bot.hasUnread ? .primary : .tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if bot.hasUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct GroupChatSidebarRow: View {
    let group: GroupChatSession
    /// See `GroupChatDetailView.resolvedMembers`'s doc comment — same
    /// reason this doesn't just read `group.members` directly.
    let allBots: [Bot]

    private var resolvedMembers: [Bot] {
        let byID = Dictionary(uniqueKeysWithValues: allBots.map { ($0.id, $0) })
        return group.memberBotIDs.compactMap { byID[$0] }
    }

    var body: some View {
        HStack(spacing: 12) {
            MemberAvatarStack(members: resolvedMembers, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.system(size: 17))
                if let preview = group.displayMessages.last {
                    Text("\(preview.speakerName): \(preview.text)")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("\(group.memberBotIDs.count) member\(group.memberBotIDs.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// The create-group sheet — name plus an up-to-6 member picker. Deliberately
/// no draft-object dance like `startNewBotDraft`'s: creating a
/// `GroupChatSession` has no expensive boot step, so there's nothing to
/// defer — `onCreate` just builds and adds it directly.
struct CreateGroupChatView: View {
    let allBots: [Bot]
    var onCreate: (String, [String]) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var memberIDs: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New group chat").font(.title2).bold()

            Text("Name").font(.caption).foregroundStyle(.secondary)
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder)

            Text("Members (\(memberIDs.count)/\(GroupChatSession.maxMembers))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if allBots.isEmpty {
                Text("Add a bot first — a group chat needs existing bots as members.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allBots) { bot in
                        let isMember = memberIDs.contains(bot.id)
                        Toggle(isOn: Binding(
                            get: { isMember },
                            set: { on in
                                if on, memberIDs.count < GroupChatSession.maxMembers { memberIDs.append(bot.id) }
                                else if !on { memberIDs.removeAll { $0 == bot.id } }
                            }
                        )) {
                            HStack {
                                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 22)
                                Text(bot.name)
                            }
                        }
                        .disabled(!isMember && memberIDs.count >= GroupChatSession.maxMembers)
                    }
                }
            }
            .frame(height: 200)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Create") { onCreate(name.isEmpty ? "New Group" : name, memberIDs) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(memberIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 500)
    }
}

/// Cross-bot "someone needs you" banner — see `ContentView.bannerBot`. Tapping
/// it navigates to that bot's own detail view, where its `ApprovalCard`
/// (already wired in `BotDetailView`) is what actually lets the user decide.
private struct ApprovalBannerView: View {
    let bot: Bot
    /// How many OTHER bots are also waiting, beyond `bot` — shown as a
    /// "+N more" suffix so a burst of delegated/group-chat approvals
    /// doesn't look like only one bot is stuck.
    let extraCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(bot.name) needs your approval")
                        .font(.system(size: 13, weight: .semibold))
                    if let toolName = bot.pendingApproval?.approval.toolName {
                        Text(extraCount > 0 ? "\(toolName) — +\(extraCount) more waiting" : toolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.orange.opacity(0.4), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 360)
    }
}

struct AppSettingsView: View {
    @Binding var appearanceMode: String
    @Binding var defaultMaxTokens: String
    @Binding var defaultMaxIterations: String
    var onSkillsChanged: () -> Void = {}
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title2).bold()

                Picker("Appearance", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)

                Divider()

                Text("Sandbox manager token").font(.headline)
                Text("The shared secret `sandbox-manager` requires on every call (X-Manager-Token). "
                    + "Get the value from MANAGER_TOKEN in the Linux host's .env.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let tokenInfo {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Set — fingerprint \(tokenInfo.fingerprint)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let modified = tokenInfo.modified {
                            Text("· updated \(modified.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Not set — bots can't reach the sandbox manager until this is added.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    SecureField("New token value", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                    Button(tokenInfo == nil ? "Save" : "Rotate") { Task { await saveToken() } }
                        .disabled(tokenInput.isEmpty || isSavingToken)
                    if tokenInfo != nil {
                        Button("Remove", role: .destructive) { Task { await removeToken() } }
                            .disabled(isSavingToken)
                    }
                }
                if let tokenStatus {
                    Text(tokenStatus).font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                Text("Debug").font(.headline)
                Toggle("Debug mode", isOn: $debugSettings.isEnabled)
                Text("Shows a live console of every bot's raw activity — status changes, tool calls and "
                    + "their results, and the model's own token stream — in a right-hand pane, including "
                    + "from group turns and delegations that are otherwise a black box in the normal chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                OllamaSettingsSection()

                Divider()

                SkillsSettingsSection(onChanged: onSkillsChanged)

                Divider()

                Text("Defaults for new bots").font(.headline)
                Text("Applied when a bot is created; each bot can still change its own after, in that bot's own settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Max tokens")
                    TextField("200000", text: $defaultMaxTokens).textFieldStyle(.roundedBorder).frame(width: 100)
                    Text("Max iterations")
                    TextField("40", text: $defaultMaxIterations).textFieldStyle(.roundedBorder).frame(width: 60)
                }

                Divider()

                HStack {
                    Text("Resource stats").font(.headline)
                    Spacer()
                    if isRefreshingStats {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") { Task { await refreshStats() } }
                        .disabled(isRefreshingStats)
                        .font(.caption)
                }

                HStack(alignment: .top, spacing: 24) {
                    MachineStatsView(title: "This Mac", stats: localStats)
                    MachineStatsView(title: "Linux host (\(RemoteHost.host))", stats: remoteStats)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 620)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.bar)
        }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            if let stats {
                if let error = stats.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
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
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }
}

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

    var body: some View {
        VStack(spacing: 0) {
            BotSettingsTab(bot: bot, groupChats: groupChats)
                .frame(maxHeight: .infinity)

            if case .edit = mode {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Danger zone").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Delete conversation…", role: .destructive) {
                            showingDeleteConversationConfirm = true
                        }
                        .disabled(bot.isBusy || bot.displayMessages.isEmpty)
                        .foregroundStyle(.red)

                        Button("Reset sandbox…", role: .destructive) {
                            showingResetSandboxConfirm = true
                        }
                        .disabled(bot.handle == nil)
                        .foregroundStyle(.red)
                        .help("Destroy this bot's Linux VM and boot a fresh one — use if it may be compromised.")

                        Button("Delete bot…", role: .destructive) {
                            showingDeleteBotConfirm = true
                        }
                        .disabled(bot.isBusy)
                        .foregroundStyle(.red)

                        Spacer()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            Divider().padding(.top, 12)
            HStack {
                Spacer()
                switch mode {
                case .edit:
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                case .create(let onSave, let onCancel):
                    Button("Cancel", role: .cancel) { onCancel() }
                    Button("Save") { onSave() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 560, height: 660)
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

private struct BotSettingsTab: View {
    @Bindable var bot: Bot
    /// Groups `bot` is currently a member of — so "Add routine" can offer
    /// firing into one of them instead of `bot`'s own chat. Not every
    /// group that exists: targeting one `bot` isn't in would just fail
    /// silently at fire time (see `GroupChatSession.fireRoutine`'s
    /// membership guard), so it's not offered as an option at all.
    var groupChats: [GroupChatSession] = []
    @State private var newMemoryText = ""
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
            VStack(alignment: .leading, spacing: 16) {
                identitySection

                DisclosureGroup("Custom Instructions") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Optional. Added to the built-in behavior (tools, how tasks finish, verification), which every bot always has and which can't be edited here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $bot.systemPromptText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 120)
                            .disabled(bot.hasStarted)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    }
                }
                .help(bot.hasStarted ? "Locked in for this conversation — start a new one to use different instructions." : "")

                DisclosureGroup("Skills (\(bot.selectedSkillIDs.count) of \(bot.availableSkills.count) selected)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: Binding(
                                get: { bot.selectedSkillIDs.count == bot.availableSkills.count && !bot.availableSkills.isEmpty },
                                set: { selectAll in
                                    bot.selectedSkillIDs = selectAll ? Set(bot.availableSkills.map(\.id)) : []
                                }
                            )) {
                                Text("Select all").font(.caption).bold()
                            }
                            .disabled(bot.hasStarted || bot.availableSkills.isEmpty)

                            Divider()

                            ForEach(bot.availableSkills) { skill in
                                Toggle(isOn: Binding(
                                    get: { bot.selectedSkillIDs.contains(skill.id) },
                                    set: { isOn in
                                        if isOn { bot.selectedSkillIDs.insert(skill.id) }
                                        else { bot.selectedSkillIDs.remove(skill.id) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(skill.name).font(.caption)
                                        if !skill.description.isEmpty {
                                            Text(skill.description)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(bot.hasStarted)
                            }
                        }
                    }
                    .frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
                .help(bot.hasStarted ? "Locked in for this conversation — start a new one to use different skills." : "")

                DisclosureGroup("Permissions (\(bot.sessionAllowedBinaries.count) this session, \(bot.globalAllowedBinaries.count) always, \(bot.blanketShellScopes.count) all-shell)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(bot.blanketShellScopes, id: \.self) { scope in
                            HStack {
                                Text("ALL shell commands").font(.system(.caption, design: .monospaced))
                                Text(blanketBadge(scope))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(4)
                                Spacer()
                                Button("Revoke") { Task { await bot.revokeAllShell(scope: scope) } }
                                    .font(.caption)
                            }
                        }
                        if bot.sessionAllowedBinaries.isEmpty && bot.globalAllowedBinaries.isEmpty && bot.blanketShellScopes.isEmpty {
                            Text("Nothing always-allowed yet — approve a run_shell command and choose "
                                + "\"Always allow…\" to add one.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(bot.sessionAllowedBinaries, id: \.self) { binary in
                            permissionRow(binary, scope: .session, badge: "session")
                        }
                        ForEach(bot.globalAllowedBinaries, id: \.self) { binary in
                            permissionRow(binary, scope: .global, badge: "always")
                        }
                    }
                    .padding(.top, 4)
                }
                .task { await bot.refreshPermissions() }

                DisclosureGroup("Memory (\(bot.memories.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions this bot has picked up — from its own `remember` tool during a "
                            + "conversation, or added here by hand. Resent at the start of every future "
                            + "conversation with it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if bot.memories.isEmpty {
                            Text("Nothing remembered yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(bot.memories.enumerated()), id: \.offset) { index, memory in
                            HStack(alignment: .top) {
                                Text(memory).font(.caption).textSelection(.enabled)
                                Spacer()
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
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addMemory() }
                            Button("Add") { addMemory() }
                                .disabled(newMemoryText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.top, 4)
                }

                DisclosureGroup("Tasks (\(bot.tasks.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("One-shot tasks this bot is carrying — from its own remember_task tool, or added "
                            + "here by hand. Unlike Memory, these are meant to be removed once done: this bot's "
                            + "own complete_task tool clears them, or remove one yourself below. They follow "
                            + "it into a group turn or a delegation, which otherwise have no access to this "
                            + "chat's history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if bot.tasks.isEmpty {
                            Text("Nothing in progress.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(bot.tasks.enumerated()), id: \.offset) { index, task in
                            HStack(alignment: .top) {
                                Text(task.text).font(.caption).textSelection(.enabled)
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
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addTask() }
                            Button("Add") { addTask() }
                                .disabled(newTaskText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.top, 4)
                }

                DisclosureGroup("Routines (\(bot.routines.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Time-based triggers that queue a message to this bot on their own — added here, "
                            + "or by the bot itself via its create_routine tool. A routine can post into a "
                            + "group chat instead of this one, if this bot is already a member of one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if bot.routines.isEmpty {
                            Text("No routines yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(bot.routines.enumerated()), id: \.offset) { index, routine in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(routine.schedule.summary).font(.caption).bold()
                                        if let groupID = routine.targetGroupID {
                                            Text("→ \(groupChats.first { $0.id == groupID }?.name ?? "deleted group")")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                        }
                                    }
                                    Text(routine.instruction)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
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
                            .padding(6)
                            .background(
                                editingRoutineID == routine.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }

                        Divider()

                        if editingRoutineID != nil {
                            Text("Editing routine").font(.caption).bold().foregroundStyle(.secondary)
                        }

                        TextField("What should it do when it fires?", text: $newRoutineInstruction)
                            .textFieldStyle(.roundedBorder)

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
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 50)
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
                            .disabled(newRoutineInstruction.trimmingCharacters(in: .whitespaces).isEmpty)

                            if editingRoutineID != nil {
                                Button("Cancel") { cancelEditingRoutine() }
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                Picker("Provider", selection: $bot.modelProvider) {
                    Text("Local (Ollama)").tag(ModelProvider.ollama)
                    Text("Remote (OpenAI-compatible)").tag(ModelProvider.remote)
                }
                .disabled(bot.hasStarted)
                .help(bot.hasStarted ? "Locked in for this conversation — start a new one to switch providers." : "")

                if bot.modelProvider == .ollama {
                    HStack {
                        Picker("Model", selection: $bot.selectedModel) {
                            ForEach(bot.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .disabled(bot.hasStarted || bot.availableModels.isEmpty)
                        .help(bot.hasStarted ? "Locked in for this conversation — start a new one to use a different model." : "")

                        Toggle("Vision", isOn: $bot.modelHasVision)
                            .disabled(bot.hasStarted)
                            .help("Whether this model can see screenshots. Ollama doesn't advertise this, so it's manual.")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Base URL (e.g. https://api.openai.com/v1)", text: $bot.remoteBaseURLText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(bot.hasStarted)
                        HStack {
                            TextField("Model id (e.g. gpt-4o)", text: $bot.selectedModel)
                                .textFieldStyle(.roundedBorder)
                                .disabled(bot.hasStarted)
                            Toggle("Vision", isOn: $bot.modelHasVision)
                                .disabled(bot.hasStarted)
                                .help("Whether this model can see screenshots — no reliable way to detect this across providers, so it's manual.")
                        }
                        SecureField("API key (leave blank to keep the saved one)", text: $bot.remoteAPIKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(bot.hasStarted)
                            .help("Stored in the Keychain, never in bots.json — typing a new value here replaces the saved one when you close this sheet.")
                    }
                }

                HStack {
                    Text("Max tokens").font(.caption)
                    TextField("200000", text: $bot.maxTokensText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(bot.hasStarted)
                    Text("Max iterations").font(.caption)
                    TextField("40", text: $bot.maxIterationsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .disabled(bot.hasStarted)
                }
                .help(bot.hasStarted
                    ? "Locked in for this conversation — start a new one to change budgets."
                    : "Raise this if you've selected several skills — the whole system prompt resends every turn, "
                    + "so a large one burns through the token budget in a handful of turns.")
            }
            .padding(20)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 68)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $bot.name).textFieldStyle(.roundedBorder)
                    TextField("Role (shown next to the name, e.g. \"UI Expert\")", text: $bot.tagline)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Text("Color").font(.caption)
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
            Text("Group").font(.caption).foregroundStyle(.secondary)
            TextField("Group (sidebar section, e.g. \"General\")", text: $bot.group)
                .textFieldStyle(.roundedBorder)
            Text("Avatar shape").font(.caption).foregroundStyle(.secondary)
            AvatarPicker(colorHex: bot.colorHex, selection: $bot.avatarStyle)
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
            Text(binary).font(.system(.caption, design: .monospaced))
            Text(badge)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
            Spacer()
            Button("Revoke") {
                Task { await bot.revokePermission(binary, scope: scope) }
            }
            .font(.caption)
        }
    }

    private func addMemory() {
        bot.addMemory(newMemoryText)
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
