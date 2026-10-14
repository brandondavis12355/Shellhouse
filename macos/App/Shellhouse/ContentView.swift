import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentCore

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
    @Environment(\.openWindow) private var openWindow
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
    @State private var showingFriends = false
    @Bindable private var friendsManager = FriendsManager.shared
    @Bindable private var joinedGroups = JoinedGroups.shared
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

    @AppStorage("appearanceMode") private var appearanceMode = "dark"
    @AppStorage("defaultMaxTokens") private var defaultMaxTokens = "200000"
    @AppStorage("defaultMaxIterations") private var defaultMaxIterations = "40"
    /// The defaults as they were when Settings opened, to tell which bots were following them.
    @State private var defaultsWhenSettingsOpened = (iterations: "40", tokens: "200000")

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

    private var selectedJoinedGroup: JoinedGroupSession? {
        guard let selectedItemID, selectedItemID.hasPrefix("joined:") else { return nil }
        let groupID = String(selectedItemID.dropFirst("joined:".count))
        return joinedGroups.sessions.first { $0.groupID == groupID }
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
        bots.filter { $0.pendingApproval != nil || $0.pendingCredentialRequest != nil }
    }

    /// The bot the banner should surface, if any — skips whichever bot is
    /// already selected, since its own `ApprovalCard` is already visible
    /// inline in `BotDetailView` and a banner for it would be redundant.
    private var bannerBot: Bot? {
        botsAwaitingApproval.first { $0.id != selectedBot?.id }
    }

    @State private var sidebarVisible = true

    private var sidebarActions: SidebarActions {
        SidebarActions(
            openSettings: { showingAppSettings = true },
            openFriends: { showingFriends = true },
            newBot: { startNewBotDraft() },
            newGroup: { startNewGroupChat() },
            importTemplate: { importBotTemplate() },
            rename: { bot in renamingBot = bot; renameText = bot.name },
            botSettings: { botSettingsTarget = $0 },
            duplicate: { duplicateBot($0) },
            exportTemplate: { exportBotAsTemplate($0) },
            delete: { pendingDeleteBot = $0 },
            groupSettings: { groupSettingsTarget = $0 },
            deleteGroup: { pendingDeleteGroup = $0 },
            reorderBot: { dragged, target in reorderBots(dragged: dragged, before: target) },
            reorderGroup: { dragged, target in reorderGroups(dragged: dragged, before: target) }
        )
    }

    @ViewBuilder
    private var detailView: some View {
        if let group = selectedGroup {
            GroupChatDetailView(group: group, allBots: bots, onOpenSettings: { groupSettingsTarget = group })
                .id(group.id)
        } else if let joined = selectedJoinedGroup {
            JoinedGroupView(session: joined, onLeft: { selectedItemID = bots.first.map { "bot:\($0.id)" } })
                .id(joined.groupID)
        } else if let bot = selectedBot {
            BotDetailView(bot: bot, onOpenSettings: { botSettingsTarget = bot })
                // Forces a fresh view identity per bot so `.onAppear`
                // in `BotDetailView` actually fires on every switch.
                .id(bot.id)
        } else {
            VStack(spacing: 8) {
                Text("No bot selected").font(.title3)
                Text("Add one with the + button, or pick one from the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 400, minHeight: 500)
        }
    }

    var body: some View {
        // Outer `HSplitView`: the debug pane gets a user-draggable divider.
        HSplitView {
        // Inner: sidebar | detail. A plain split rather than
        // `NavigationSplitView` so the sidebar is a flat black list with no
        // system material or floating chrome.
        HSplitView {
            if sidebarVisible {
                SidebarView(
                    groupedBots: groupedBots,
                    allBots: bots,
                    groupChats: groupChats,
                    joinedGroups: joinedGroups.sessions,
                    selectedItemID: $selectedItemID,
                    friendRequestCount: friendsManager.incomingCount,
                    actions: sidebarActions
                )
                .frame(minWidth: 270, idealWidth: 320, maxWidth: 380)
            }
            // Switching chats crossfades: each chat view has its own identity (see `detailView`), so the
            // old one fades out while the new one fades and settles in.
            ZStack {
                detailView
                    .transition(.paneSwap)
            }
            .motion(Motion.smooth, value: selectedItemID)
                // The chat column never gets narrower than its header and composer need.
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
        .background(Theme.bg)
        .environment(\.sidebarControl, SidebarControl(isVisible: sidebarVisible, toggle: { sidebarVisible.toggle() }))
        .tint(Theme.accent)
        .buttonStyle(.pill)
        .preferredColorScheme(preferredColorScheme)
        .task { await ModelTiers.autoConfigure() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Debounced saves would otherwise lose the last few hundred ms of messages.
            bots.forEach { $0.flushTranscriptNow() }
            groupChats.forEach { $0.flushPersistenceNow() }
        }
        .onChange(of: joinedGroups.sessions.map(\.groupID)) { _, ids in
            // A joined group vanished (removed, left, deleted): don't leave it selected.
            if let selected = selectedItemID, selected.hasPrefix("joined:"),
               !ids.contains(String(selected.dropFirst("joined:".count))) {
                selectedItemID = bots.first.map { "bot:\($0.id)" }
            }
        }
        .sheet(isPresented: $showingFriends) {
            FriendsView()
        }
        .onChange(of: showingAppSettings) { _, open in
            if open { defaultsWhenSettingsOpened = (defaultMaxIterations, defaultMaxTokens) }
        }
        .sheet(isPresented: $showingAppSettings, onDismiss: applyChangedBotDefaults) {
            AppSettingsView(
                appearanceMode: $appearanceMode,
                defaultMaxTokens: $defaultMaxTokens,
                defaultMaxIterations: $defaultMaxIterations,
                onSkillsChanged: { for bot in bots { bot.refreshAvailableSkills() } },
                onApplyDefaultsToAllBots: {
                    for bot in bots {
                        bot.maxIterationsText = defaultMaxIterations
                        bot.maxTokensText = defaultMaxTokens
                    }
                    saveBots()
                    defaultsWhenSettingsOpened = (defaultMaxIterations, defaultMaxTokens)
                },
                onHostChanged: { rebootStalledBots() },
                onManagerTokenChanged: { rebootStalledBots() },
                onExportSettings: { includeSecrets in exportSettings(includeSecrets: includeSecrets) },
                onImportSettings: { importSettingsFromPanel() }
            )
        }
        .background(liveSettingsObserver)
        .onReceive(NotificationCenter.default.publisher(for: .openAppSettings)) { _ in showingAppSettings = true }
        .sheet(item: $botSettingsTarget) { bot in
            BotSettingsView(bot: bot, groupChats: groupChats, onDeleteBot: { deleteBotPermanently(bot) })
                // Saved as you edit (debounced), so nothing waits for the sheet to close.
                .onChange(of: bot.config) { _, _ in scheduleSaveBots() }
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
            }
        }
        .motion(Motion.settle, value: bannerBot?.id)
        .task {
            // `create_bot`/`add_bot_to_group` tool support — see
            // `BotDirectory`'s doc comments. Same "no confirmation sheet"
            // shape as the first-launch `addBot` bootstrap below: a tool
            // call isn't a place to show a settings sheet, so this commits
            // immediately.
            botDirectory.createBot = { name, tagline, configure in
                let botID = "bot-\(UUID().uuidString.prefix(8))"
                let colorHex = botColorPalette[bots.count % botColorPalette.count]
                let bot = Bot(id: botID, name: name, colorHex: colorHex, tagline: tagline, permissions: runShellPermissions, botDirectory: botDirectory)
                bot.maxTokensText = defaultMaxTokens
                bot.maxIterationsText = defaultMaxIterations
                configure(bot)
                bots.append(bot)
                botDirectory.sync(bots)
                saveBots()
                Task { await bot.boot() }
                return bot
            }
            botDirectory.saveBots = { saveBots() }
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
            groupChats = GroupChatStore.load().map { GroupChatSession(id: $0.id, name: $0.name, memberBotIDs: $0.memberBotIDs, botDirectory: botDirectory, coordinatorBotID: $0.coordinatorBotID, stallLimit: $0.stallLimit, confirmTimeoutMinutes: $0.confirmTimeoutMinutes, relayGroupID: $0.relayGroupID) }
            botDirectory.syncGroups(groupChats)
            StartupConfigLogger.log(bots: bots, groups: groupChats)
            // Reconnect to the friends relay (if configured) so the sidebar
            // badge reflects pending requests without opening the sheet.
            await FriendsManager.shared.connectIfConfigured()
            FriendsManager.shared.startAutoRefresh()
            for group in groupChats { group.startRelayIfShared() }
            // Shared groups follow the relay connection: (re)start sync whenever
            // it comes up (including a later connect from the Friends sheet),
            // stop it when it goes away.
            FriendsManager.shared.onConnected = { for group in groupChats { group.startRelayIfShared() } }
            FriendsManager.shared.onDisconnected = { for group in groupChats { group.stopRelay() } }
        }
        .onChange(of: DebugSettings.shared.isEnabled) { _, isOn in
            if isOn {
                StartupConfigLogger.log(bots: bots, groups: groupChats)
                openWindow(id: "debug-console")
            }
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

    /// Drag-reorder within a sidebar section: `dragged` takes the slot just
    /// before `target`. Only within the same section (see `moveBots`).
    private func reorderBots(dragged: String, before target: String) {
        guard let from = bots.firstIndex(where: { $0.id == dragged }),
              let to = bots.firstIndex(where: { $0.id == target }),
              bots[from].group == bots[to].group else { return }
        let moved = bots.remove(at: from)
        let insertAt = bots.firstIndex(where: { $0.id == target }) ?? bots.endIndex
        bots.insert(moved, at: insertAt)
        botDirectory.sync(bots)
        saveBots()
    }

    private func reorderGroups(dragged: String, before target: String) {
        guard let from = groupChats.firstIndex(where: { $0.id == dragged }),
              groupChats.contains(where: { $0.id == target }) else { return }
        let moved = groupChats.remove(at: from)
        let insertAt = groupChats.firstIndex(where: { $0.id == target }) ?? groupChats.endIndex
        groupChats.insert(moved, at: insertAt)
        saveGroupChats()
    }

    private func saveGroupChats() {
        GroupChatStore.save(groupChats.map(\.config))
    }

    private func deleteGroupPermanently(_ group: GroupChatSession) {
        groupChats.removeAll { $0.id == group.id }
        botDirectory.syncGroups(groupChats)
        if selectedItemID == "group:\(group.id)" { selectedItemID = nil }
        Task { await group.deleteRelayCopy() }
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
        if !bot.memoryBook.entries.isEmpty { BotMemoryStore.saveBook(id: bot.id, bot.memoryBook) }
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

    /// Invisible: carries the handlers that apply settings the moment they change (kept out of `body`'s long
    /// modifier chain, which the compiler can't type-check in time otherwise).
    private var liveSettingsObserver: some View {
        Color.clear
            // Settings files opened from Finder, `open`, or initial_setup.sh.
            .onChange(of: ExternalRequests.shared.pendingSettingsFiles) { _, files in
                guard !files.isEmpty else { return }
                ExternalRequests.shared.pendingSettingsFiles = []
                Task { @MainActor in
                    for url in files {
                        await importSettings(from: url, askFirst: SettingsBundle.isQuarantined(url), receipt: true)
                    }
                }
            }
            // Defaults for new bots apply as you type, not when the sheet closes: bots still on the old default follow.
            .onChange(of: defaultMaxIterations) { _, _ in
                applyChangedBotDefaults(); defaultsWhenSettingsOpened = (defaultMaxIterations, defaultMaxTokens)
            }
            .onChange(of: defaultMaxTokens) { _, _ in
                applyChangedBotDefaults(); defaultsWhenSettingsOpened = (defaultMaxIterations, defaultMaxTokens)
            }
    }

    // MARK: - Settings export / import

    private func exportSettings(includeSecrets: Bool) {
        Task { @MainActor in
            guard let data = await SettingsBundle.export(bots: bots.map(\.config), groups: groupChats.map(\.config),
                                                         includeSecrets: includeSecrets) else {
                showExportError("Couldn't build the settings file.", SettingsBundle.BundleError.notSettings)
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: SettingsBundle.fileExtension) ?? .propertyList]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = includeSecrets ? "Shellhouse Settings (with secrets).shellhousesettings" : "Shellhouse Settings.shellhousesettings"
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    // Secrets in the file: only you can read it.
                    if includeSecrets { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                } catch {
                    showExportError("Couldn't save the settings to \(url.lastPathComponent).", error)
                }
            }
            if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
            else { panel.begin(completionHandler: finish) }
        }
    }

    private func importSettingsFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SettingsBundle.fileExtension) ?? .propertyList, .propertyList, .xml]
        panel.allowsMultipleSelection = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await importSettings(from: url, askFirst: false, receipt: false) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    /// `askFirst`: the file came from outside the app and macOS marks it as downloaded, so show what it would change
    /// before applying. `receipt`: overwrite the file afterwards so any secrets in it don't stay on disk.
    @MainActor
    private func importSettings(from url: URL, askFirst: Bool, receipt: Bool) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let contents: SettingsBundle.Contents
        do {
            contents = try SettingsBundle.parse(try Data(contentsOf: url))
        } catch {
            showExportError("Couldn't import \(url.lastPathComponent).", error)
            return
        }
        if askFirst {
            let alert = NSAlert()
            alert.messageText = "Import settings from \(url.lastPathComponent)?"
            alert.informativeText = "This file was downloaded. It would change \(contents.summary)"
                + (contents.host.map { ", and connect the app to the Linux host \($0)" } ?? "")
                + ". Only import settings from someone you trust."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        await applySettings(contents)
        if receipt { SettingsBundle.writeReceipt(to: url, summary: contents.summary) }
        let done = NSAlert()
        done.messageText = "Settings imported"
        done.informativeText = "Applied \(contents.summary). Everything takes effect now."
        if !receipt || askFirst { done.runModal() }
    }

    @MainActor
    private func applySettings(_ contents: SettingsBundle.Contents) async {
        SettingsBundle.applyAppSettings(contents)
        await runShellPermissions.reloadFromDefaults()

        // Bots: matched by id, then by name; new ones are created and started.
        var idMap: [String: String] = [:]
        var created: [Bot] = []
        for config in contents.bots {
            if let bot = bots.first(where: { $0.id == config.id })
                ?? bots.first(where: { $0.name.caseInsensitiveCompare(config.name) == .orderedSame }) {
                bot.apply(config)
                idMap[config.id] = bot.id
            } else {
                let bot = Bot(config: config, permissions: runShellPermissions, botDirectory: botDirectory)
                bots.append(bot)
                created.append(bot)
                idMap[config.id] = bot.id
            }
        }
        if !contents.bots.isEmpty {
            botDirectory.sync(bots)
            saveBots()
        }

        // Secrets, with per-bot model keys renamed to the matching local bot.
        let store = SecretStore()
        for (name, value) in contents.secrets {
            var localName = name
            for (imported, local) in idMap where imported != local {
                let importedKey = "REMOTE_API_KEY_" + imported.uppercased().replacingOccurrences(of: "-", with: "_")
                if name.hasPrefix(importedKey) {
                    localName = "REMOTE_API_KEY_" + local.uppercased().replacingOccurrences(of: "-", with: "_") + name.dropFirst(importedKey.count)
                }
            }
            try? await store.put(name: localName, value: value)
        }
        if let token = contents.secrets[managerTokenName] { RemoteSandboxManager.sharedToken.value = token }

        // Groups: matched by id, then by name; members mapped to this app's bots.
        for record in contents.groups {
            let members = record.memberBotIDs.compactMap { id in idMap[id] ?? (bots.contains { $0.id == id } ? id : nil) }
            let coordinator = record.coordinatorBotID.flatMap { idMap[$0] ?? $0 }.flatMap { id in members.contains(id) ? id : nil }
            if let group = groupChats.first(where: { $0.id == record.id })
                ?? groupChats.first(where: { $0.name.caseInsensitiveCompare(record.name) == .orderedSame }) {
                group.name = record.name
                if !members.isEmpty { group.memberBotIDs = members }
                group.coordinatorBotID = coordinator ?? group.coordinatorBotID
                if let limit = record.stallLimit { group.stallLimit = limit }
                if let minutes = record.confirmTimeoutMinutes { group.confirmTimeoutMinutes = minutes }
            } else if !members.isEmpty {
                groupChats.append(GroupChatSession(
                    id: record.id, name: record.name, memberBotIDs: members, botDirectory: botDirectory,
                    coordinatorBotID: coordinator, stallLimit: record.stallLimit, confirmTimeoutMinutes: record.confirmTimeoutMinutes,
                    relayGroupID: nil
                ))
            }
        }
        if !contents.groups.isEmpty {
            botDirectory.syncGroups(groupChats)
            saveGroupChats()
        }

        // The host and the smolagents forward: reconnect the tunnel now.
        if contents.app["linuxHostSettings.v1"] != nil || contents.app["smolagents.config.v1"] != nil {
            let host = HostSettingsStore.load()
            AppDelegate.shared?.tunnel.reconfigure(.init(
                host: host.host, user: host.user, managerSocketPath: host.managerSocketPath,
                reverseForwards: SmolAgentsService.reverseForwards()
            ))
        }
        for bot in created { Task { await bot.boot() } }
        rebootStalledBots()
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

    /// Bots still on the old default follow a changed default (a bot given its own value keeps it).
    private func applyChangedBotDefaults() {
        var changed = false
        for bot in bots {
            if bot.maxIterationsText == defaultsWhenSettingsOpened.iterations, bot.maxIterationsText != defaultMaxIterations {
                bot.maxIterationsText = defaultMaxIterations; changed = true
            }
            if bot.maxTokensText == defaultsWhenSettingsOpened.tokens, bot.maxTokensText != defaultMaxTokens {
                bot.maxTokensText = defaultMaxTokens; changed = true
            }
        }
        if changed { saveBots() }
    }

    /// Re-boots bots that have no sandbox or failed to start: after the host or the manager token changed.
    /// (`boot()` waits for the tunnel itself.)
    private func rebootStalledBots() {
        for bot in bots where !bot.isBusy {
            if bot.handle == nil { Task { await bot.boot() }; continue }
            if case .failed = bot.state { Task { await bot.boot() } }
        }
    }

    @State private var saveBotsTask: Task<Void, Never>?
    private func scheduleSaveBots() {
        saveBotsTask?.cancel()
        saveBotsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveBots()
        }
    }

    private func saveBots() {
        BotStore.save(bots.map(\.config))
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
                    Text(bot.pendingApproval == nil && bot.pendingCredentialRequest != nil
                         ? "\(bot.name) needs credentials" : "\(bot.name) needs your approval")
                        .font(.system(size: 13, weight: .semibold))
                    if let toolName = bot.pendingApproval?.approval.toolName ?? bot.pendingCredentialRequest.map({ _ in "request_credentials" }) {
                        Text(extraCount > 0 ? "\(toolName) — +\(extraCount) more waiting" : toolName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 360)
    }
}
