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
        bots.filter { $0.pendingApproval != nil }
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
            detailView
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
        .sheet(isPresented: $showingAppSettings) {
            AppSettingsView(
                appearanceMode: $appearanceMode,
                defaultMaxTokens: $defaultMaxTokens,
                defaultMaxIterations: $defaultMaxIterations,
                onSkillsChanged: { for bot in bots { bot.refreshAvailableSkills() } },
                onHostChanged: {
                    // Give the new tunnel a few seconds, then re-boot any bot that
                    // never got its sandbox (boot() itself waits for the tunnel).
                    for bot in bots where bot.handle == nil { Task { await bot.boot() } }
                }
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
                .background(Theme.bg)
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
        SheetScaffold(title: "New group chat", onClose: onCancel) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Name")
                Card {
                    TextField("Group name", text: $name)
                        .themedField()
                        .padding(16)
                }

                SectionLabel("Members (\(memberIDs.count)/\(GroupChatSession.maxMembers))")
                if allBots.isEmpty {
                    Card {
                        SettingRow("Add a bot first", subtitle: "A group chat needs existing bots as members.", titleColor: .secondary)
                    }
                } else {
                    Card {
                        ForEach(Array(allBots.enumerated()), id: \.element.id) { index, bot in
                            let isMember = memberIDs.contains(bot.id)
                            if index > 0 { CardDivider() }
                            HStack(spacing: 12) {
                                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 28)
                                Text(bot.name).font(.system(size: 16))
                                Spacer(minLength: 12)
                                Toggle("", isOn: Binding(
                                    get: { isMember },
                                    set: { on in
                                        if on, memberIDs.count < GroupChatSession.maxMembers { memberIDs.append(bot.id) }
                                        else if !on { memberIDs.removeAll { $0 == bot.id } }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(Theme.positive)
                                .disabled(!isMember && memberIDs.count >= GroupChatSession.maxMembers)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 50)
                        }
                    }
                }
            }
        } footer: {
            SheetFooter {
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Create") { onCreate(name.isEmpty ? "New Group" : name, memberIDs) }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(memberIDs.isEmpty)
            }
        }
        .frame(width: 480, height: 560)
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

struct AppSettingsView: View {
    @Binding var appearanceMode: String
    @Binding var defaultMaxTokens: String
    @Binding var defaultMaxIterations: String
    var onSkillsChanged: () -> Void = {}
    /// The Linux host's address was saved — bots that couldn't reach the
    /// sandbox before should try again.
    var onHostChanged: () -> Void = {}
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

                AgentEngineSettingsSection()

                HostSettingsSection(onChanged: onHostChanged)

                SectionLabel("Sandbox manager token")
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

                SectionLabel("Defaults for new bots")
                Card {
                    SettingRow("Max tokens") {
                        TextField("200000", text: $defaultMaxTokens).themedField().frame(width: 120)
                    }
                    CardDivider()
                    SettingRow("Max iterations") {
                        TextField("40", text: $defaultMaxIterations).themedField().frame(width: 120)
                    }
                }
                SectionFooter("Applied when a bot is created; each bot can still change its own after, in that bot's own settings.")

                HStack {
                    SectionLabel("Resource stats")
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
                    SectionLabel("Danger zone")
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

private struct BotSettingsTab: View {
    @Bindable var bot: Bot
    /// Groups `bot` is currently a member of — so "Add routine" can offer
    /// firing into one of them instead of `bot`'s own chat. Not every
    /// group that exists: targeting one `bot` isn't in would just fail
    /// silently at fire time (see `GroupChatSession.fireRoutine`'s
    /// membership guard), so it's not offered as an option at all.
    var groupChats: [GroupChatSession] = []
    @State private var newMemoryText = ""
    @State private var tidyNote: String?
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

                ExpandableCard("Custom Instructions", summary: bot.systemPromptText.isEmpty ? "None" : "Set") {
                    Text("Optional. Added to the built-in behavior (tools, how tasks finish, verification), which every bot always has and which can't be edited here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $bot.systemPromptText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(height: 120)
                        .disabled(bot.hasStarted)
                        .themedEditor()
                }
                .help(bot.hasStarted ? "Locked in for this conversation — start a new one to use different instructions." : "")
                .padding(.top, 16)

                ExpandableCard("Skills", summary: "\(bot.selectedSkillIDs.count) of \(bot.availableSkills.count)") {
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
                            .disabled(bot.hasStarted || bot.availableSkills.isEmpty)

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
                                .disabled(bot.hasStarted)
                            }
                        }
                    }
                    .frame(height: 200)
                }
                .help(bot.hasStarted ? "Locked in for this conversation — start a new one to use different skills." : "")
                .padding(.top, 12)

                ExpandableCard("Permissions", summary: "\(bot.sessionAllowedBinaries.count) session · \(bot.globalAllowedBinaries.count) always · \(bot.blanketShellScopes.count) all-shell") {
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

                ExpandableCard("Memory", summary: "\(bot.memories.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes this bot keeps — from its own `remember` tool during a "
                            + "conversation, or added here by hand. Pinned and high-importance notes go in every prompt; "
                            + "the rest appear when relevant to a message.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if !bot.memories.isEmpty {
                            let model = ModelTiers.embeddingModel
                            Text(model.isEmpty
                                 ? "Search is by keywords. Pick an embedding model in Settings › Fast model to also search by meaning."
                                 : "\(bot.memoriesIndexed) of \(bot.memories.count) notes indexed for meaning (\(model)).")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        if bot.memories.isEmpty {
                            Text("Nothing remembered yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(bot.memoryBook.entries.enumerated()), id: \.element.id) { index, entry in
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
                                    Text("importance \(String(repeating: "●", count: entry.importance))\(String(repeating: "○", count: 5 - entry.importance))"
                                        + (entry.useCount > 0 ? " · used \(entry.useCount)×" : "") + " · \(entry.source)")
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                Spacer()
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

                ExpandableCard("Tasks", summary: "\(bot.tasks.count)") {
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

                ExpandableCard("Routines", summary: "\(bot.routines.count)") {
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
                .padding(.top, 12)

                SectionLabel("Linux VM")
                Card {
                    SettingRow(
                        bot.handle.map { "shellhouse-vm-\($0.id)" } ?? "Not running",
                        subtitle: "This bot's own private Linux VM. Its files and installed packages are not visible to any other bot."
                    ) {
                        Image(systemName: "desktopcomputer").foregroundStyle(bot.sandbox == nil ? Color.secondary : Theme.positive)
                    }
                }

                SectionLabel("Model")
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
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .disabled(bot.isBusy || bot.availableModels.isEmpty)
                            .help(bot.isBusy ? "Locked while this bot is working — change it once it's idle. The conversation carries over." : "")
                        }
                        CardDivider()
                        ToggleRow(title: "Vision", subtitle: "Whether this model can see screenshots. Ollama doesn't advertise this, so it's manual.", isOn: $bot.modelHasVision)
                            .disabled(bot.isBusy)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
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

                    SettingRow("Max tokens") {
                        TextField("200000", text: $bot.maxTokensText)
                            .themedField()
                            .frame(width: 110)
                            .disabled(bot.isBusy)
                    }
                    CardDivider()
                    SettingRow("Max iterations") {
                        TextField("40", text: $bot.maxIterationsText)
                            .themedField()
                            .frame(width: 110)
                            .disabled(bot.isBusy)
                    }
                }
                .help(bot.isBusy
                    ? "Locked while this bot is working."
                    : "Raise this if you've selected several skills — the whole system prompt resends every turn, "
                    + "so a large one burns through the token budget in a handful of turns.")
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

            SectionLabel("Avatar shape")
            Card {
                AvatarPicker(colorHex: bot.colorHex, selection: $bot.avatarStyle)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

/// Guardrail options and a look at the tamper-evident audit log
/// (docs/GUARDRAILS.md). Destructive and credential actions are always gated;
/// the only loosening offered here is the opt-in read-only shell fast path.
struct GuardrailSettingsSection: View {
    @AppStorage("guardrails.autoAllowReadOnlyShell") private var autoAllowReadOnlyShell = false
    @AppStorage("guardrails.yolo") private var yolo = false
    @State private var confirmingYolo = false
    @State private var entries: [AuditLog.Entry] = []
    @State private var verification: AuditLog.Verification?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Guardrails")
            Card {
                ToggleRow(
                    title: "YOLO mode — don't ask for approval",
                    subtitle: "Bots run ordinary actions without a prompt: shell commands, file changes, installs. Still blocked or still asking: "
                        + "credential theft and exfiltration (hard blocks), anything that changes something after a bot has read untrusted "
                        + "content (web pages, downloads; read-only commands like `gh --version` still run), friends' messages, and other high-risk actions. Everything is still written to the audit log. Off by default.",
                    isOn: Binding(
                        get: { yolo },
                        set: { on in if on { confirmingYolo = true } else { yolo = false } }
                    )
                )
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
            Text("Bots will run commands and change files in their VMs without asking you first. Hard blocks stay in place, and a bot "
                + "that has read untrusted content will still ask. You can turn this off at any time.")
        }
    }

    private func color(for outcome: String) -> Color {
        switch outcome {
        case "denied", "tripwire", "run_frozen", "denied_by_user", "approval_expired": return Theme.destructive
        case "quarantined": return Theme.warning
        case "approved", "auto", "granted_binary", "granted_blanket", "yolo_auto": return Theme.positive
        default: return .secondary
        }
    }
}

/// Setup for the experimental smolagents engine (docs/SMOLAGENTS.md): where
/// sandboxes can reach the Mac's token-gated model proxy.
struct AgentEngineSettingsSection: View {
    @State private var config = SmolAgentsService.shared.config
    @State private var status: String?

    private var addressValid: Bool { SmolAgentsService.Config.isPrivateIPv4(config.sandboxAddress) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Agent engine (experimental)")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Lets a bot run on smolagents inside its own sandbox. The sandbox reaches your Mac's local models only through a "
                        + "loopback proxy exposed over the existing SSH connection, with a one-run token; no model credentials enter the sandbox. "
                        + "Needs `GatewayPorts clientspecified` on the Linux host's sshd, and a sandbox image built with the runner.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    TextField("Docker bridge address on the Linux host (e.g. 172.18.0.1)", text: $config.sandboxAddress)
                        .themedField()
                    if !config.sandboxAddress.isEmpty && !addressValid {
                        Text("Must be a private IPv4 address (10.x, 172.16–31.x or 192.168.x). Wildcards and public addresses are refused.")
                            .font(.system(size: 12)).foregroundStyle(Theme.warning)
                    }
                    TextField("Address sandboxes use, if different (e.g. egress-proxy in allowlist mode)", text: $config.sandboxVisibleHost)
                        .themedField()
                    HStack {
                        Text("Proxy port").font(.system(size: 14))
                        TextField("18434", value: $config.proxyPort, format: .number.grouping(.never))
                            .themedField().frame(width: 100)
                        Spacer()
                        Button("Save & reconnect") { save() }.disabled(!config.isConfigured)
                    }
                    if let status { Text(status).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(16)
            }
        }
    }

    private func save() {
        SmolAgentsService.shared.config = config
        let host = HostSettingsStore.load()
        AppDelegate.shared?.tunnel.reconfigure(.init(
            host: host.host, user: host.user, managerSocketPath: host.managerSocketPath,
            reverseForwards: SmolAgentsService.reverseForwards()
        ))
        status = "Saved. The tunnel is reconnecting with the model proxy forward (\(config.sandboxAddress):\(config.proxyPort))."
    }
}


/// Settings › Fast model: the cheap tier for reply checks, small talk and parallel helpers.
struct ModelTiersSettingsSection: View {
    @State private var fastModel = ModelTiers.fastModel
    @State private var embeddingModel = ModelTiers.embeddingModel
    @State private var installed: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Fast model")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A small model for the quick decisions around each reply (does this need an answer, is it small talk) "
                        + "and for the `ask_helpers` tool that lets a bot run sub-tasks in parallel. Each bot's own model still does "
                        + "the real work. For parallel helpers, Ollama needs OLLAMA_NUM_PARALLEL of 2 or more and room for a second "
                        + "model (OLLAMA_MAX_LOADED_MODELS) — see docs/MODEL_TIERS.md.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack {
                        Picker("Fast model", selection: $fastModel) {
                            Text("None (use each bot's model)").tag("")
                            ForEach(installed, id: \.self) { Text($0).tag($0) }
                            if !fastModel.isEmpty && !installed.contains(fastModel) { Text(fastModel).tag(fastModel) }
                        }
                        .labelsHidden()
                        .onChange(of: fastModel) { _, new in ModelTiers.fastModel = new }
                        if let suggestion = ModelTiers.suggestedFastModel(from: installed), fastModel.isEmpty {
                            Button("Use \(suggestion)") { fastModel = suggestion }
                        }
                    }
                    HStack {
                        Text("Memory embeddings").font(.system(size: 13)).foregroundStyle(.secondary)
                        Picker("Memory embedding model", selection: $embeddingModel) {
                            Text("None (keywords only)").tag("")
                            ForEach(ModelTiers.embeddingModels(from: installed), id: \.self) { Text($0).tag($0) }
                            if !embeddingModel.isEmpty && !installed.contains(embeddingModel) { Text(embeddingModel).tag(embeddingModel) }
                        }
                        .labelsHidden()
                        .onChange(of: embeddingModel) { _, new in ModelTiers.embeddingModel = new }
                    }
                    Text("Lets bots find notes by meaning (\"the github tool\" finds the note about gh). Notes are indexed in the background; "
                        + "the model stays loaded only for a few minutes after use.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .padding(16)
            }
        }
        .task {
            installed = ((try? await OllamaBackend().availableModels()) ?? []).sorted()
            await ModelTiers.autoConfigure()
            fastModel = ModelTiers.fastModel
            embeddingModel = ModelTiers.embeddingModel
            if embeddingModel.isEmpty, let pick = await ModelTiers.resolveEmbeddingModel() { embeddingModel = pick }
        }
    }
}


/// Settings › Accuracy: one switch per group of accuracy features. All on by default; the card collapses to a
/// one-line summary and remembers whether you left it open.
struct AccuracySettingsSection: View {
    @AppStorage("settings.accuracyExpanded") private var isExpanded = false
    @State private var tick = 0   // forces a refresh after a switch changes

    private func binding(_ feature: Reliability.Feature) -> Binding<Bool> {
        Binding(get: { _ = tick; return Reliability.isOn(feature) }, set: { Reliability.set(feature, $0); tick += 1 })
    }

    private var summary: String {
        _ = tick
        let on = Reliability.Feature.allCases.filter { Reliability.isOn($0) }.count
        let total = Reliability.Feature.allCases.count
        return on == total ? "All \(total) on" : "\(on) of \(total) on"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    SettingRow("Accuracy", subtitle: isExpanded ? nil : "Checks that keep bot answers and actions correct") {
                        HStack(spacing: 8) {
                            Text(summary).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                    }
                }
                .buttonStyle(.plain)
                if isExpanded {
                    ForEach(Reliability.Feature.allCases, id: \.self) { feature in
                        CardDivider()
                        ToggleRow(title: feature.title, subtitle: feature.detail, isOn: binding(feature))
                    }
                    CardDivider()
                    SettingRow("Recommended settings", subtitle: "Turn every accuracy feature back on.") {
                        Button("Turn all on") { Reliability.resetAll(); tick += 1 }
                            .buttonStyle(.compactPill)
                            .disabled(Reliability.Feature.allCases.allSatisfy { Reliability.isOn($0) })
                    }
                }
            }
            if isExpanded {
                SectionFooter("Safety rules, approvals and loop-breaking bug fixes are not affected by these switches.")
            }
        }
        .padding(.top, 12)
    }
}
