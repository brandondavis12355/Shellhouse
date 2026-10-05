import AgentCore
import SwiftUI

/// Everything the sidebar can ask `ContentView` to do — closures rather than
/// bindings so the sidebar stays a dumb, fast-to-type-check view.
struct SidebarActions {
    var openSettings: () -> Void = {}
    var openFriends: () -> Void = {}
    var newBot: () -> Void = {}
    var newGroup: () -> Void = {}
    var importTemplate: () -> Void = {}
    var rename: (Bot) -> Void = { _ in }
    var botSettings: (Bot) -> Void = { _ in }
    var duplicate: (Bot) -> Void = { _ in }
    var exportTemplate: (Bot) -> Void = { _ in }
    var delete: (Bot) -> Void = { _ in }
    var groupSettings: (GroupChatSession) -> Void = { _ in }
    var deleteGroup: (GroupChatSession) -> Void = { _ in }
    /// Drag-reorder: move `dragged` to sit just before `target`.
    var reorderBot: (_ dragged: String, _ before: String) -> Void = { _, _ in }
    var reorderGroup: (_ dragged: String, _ before: String) -> Void = { _, _ in }
}

/// Flat, black conversation list: group chats as centered emblem tiles on
/// top, then bots under collapsible section headers — avatar, name, role
/// pill, last-activity stamp and a one-line preview per row.
struct SidebarView: View {
    let groupedBots: [(group: String, bots: [Bot])]
    let allBots: [Bot]
    let groupChats: [GroupChatSession]
    let joinedGroups: [JoinedGroupSession]
    @Binding var selectedItemID: String?
    let friendRequestCount: Int
    let actions: SidebarActions

    @State private var collapsed: Set<String> = []
    @State private var isSearching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ bot: Bot) -> Bool {
        trimmedQuery.isEmpty
            || bot.name.lowercased().contains(trimmedQuery)
            || bot.tagline.lowercased().contains(trimmedQuery)
            || (bot.lastMessagePreview?.lowercased().contains(trimmedQuery) ?? false)
    }

    private func matches(_ group: GroupChatSession) -> Bool {
        trimmedQuery.isEmpty || group.name.lowercased().contains(trimmedQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isSearching { searchField }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    groupTiles
                    ForEach(groupedBots, id: \.group) { section in
                        botSection(section.group, section.bots)
                    }
                    joinedSection
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.bg)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            GlassCircleButton(systemName: "gearshape", size: 36, help: "Settings", action: actions.openSettings)
            GlassCircleButton(systemName: "person.2", size: 36, help: "Friends — connect to a relay, invite people, accept requests.", action: actions.openFriends)
                .overlay(alignment: .topTrailing) {
                    if friendRequestCount > 0 {
                        Text("\(friendRequestCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.destructive, in: Capsule())
                            .offset(x: 4, y: -3)
                    }
                }
            GlassCircleButton(systemName: isSearching ? "xmark" : "magnifyingglass", size: 36, help: "Search") {
                isSearching.toggle()
                if isSearching { searchFocused = true } else { query = "" }
            }
            GlassCircleMenu(systemName: "plus", size: 36, help: "Add a bot (its own sandbox), a group chat (up to 6 existing bots), or a bot imported from a template file.") {
                Button("New bot…", action: actions.newBot)
                Button("New group chat…", action: actions.newGroup)
                Divider()
                Button("Friends…", action: actions.openFriends)
                Button("New bot from template…", action: actions.importTemplate)
            }
        }
        .padding(.horizontal, 12)
        // Clears the window's traffic lights, which float over this corner.
        .padding(.leading, 70)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Group chats

    @ViewBuilder
    private var groupTiles: some View {
        let visible = groupChats.filter(matches)
        if !visible.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    tiles(visible)
                }
                .frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 6) {
                        tiles(visible)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, 8)
        }
    }


    @ViewBuilder
    private func tiles(_ visible: [GroupChatSession]) -> some View {
        ForEach(visible) { group in
            GroupTile(group: group, allBots: allBots, isSelected: selectedItemID == "group:\(group.id)")
                .onTapGesture { selectedItemID = "group:\(group.id)" }
                .contextMenu {
                    Button("Group settings…") { actions.groupSettings(group) }
                    Divider()
                    Button("Delete…", role: .destructive) { actions.deleteGroup(group) }
                }
                .draggable(group.id)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first, dragged != group.id else { return false }
                    actions.reorderGroup(dragged, group.id)
                    return true
                }
        }
    }

    // MARK: Bots

    @ViewBuilder
    private func botSection(_ title: String, _ bots: [Bot]) -> some View {
        let visible = bots.filter(matches)
        if !visible.isEmpty {
            let isCollapsed = collapsed.contains(title) && trimmedQuery.isEmpty
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 17)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(visible) { bot in
                    BotSidebarRow(bot: bot, isSelected: selectedItemID == "bot:\(bot.id)")
                        .onTapGesture { selectedItemID = "bot:\(bot.id)" }
                        .contextMenu {
                            Button("Rename…") { actions.rename(bot) }
                            Button("Bot settings…") { actions.botSettings(bot) }
                            Divider()
                            Button("Duplicate…") { actions.duplicate(bot) }
                            Button("Export as template…") { actions.exportTemplate(bot) }
                            Divider()
                            Button("Delete…", role: .destructive) { actions.delete(bot) }
                        }
                        .draggable(bot.id)
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first, dragged != bot.id else { return false }
                            actions.reorderBot(dragged, bot.id)
                            return true
                        }
                }
            }
        }
    }

    // MARK: Shared with me

    @ViewBuilder
    private var joinedSection: some View {
        let visible = joinedGroups.filter { trimmedQuery.isEmpty || $0.name.lowercased().contains(trimmedQuery) }
        if !visible.isEmpty {
            Text("Shared with me")
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
            ForEach(visible) { session in
                JoinedGroupSidebarRow(session: session, isSelected: selectedItemID == "joined:\(session.groupID)")
                    .onTapGesture { selectedItemID = "joined:\(session.groupID)" }
            }
        }
    }
}

// MARK: - Rows

/// A group chat's emblem tile with its name underneath.
private struct GroupTile: View {
    let group: GroupChatSession
    let allBots: [Bot]
    let isSelected: Bool

    private var members: [Bot] {
        let byID = Dictionary(uniqueKeysWithValues: allBots.map { ($0.id, $0) })
        return group.memberBotIDs.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(spacing: 6) {
            AvatarCluster(members: members, size: 96)
            Text(group.name)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 108)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .help(group.displayMessages.last.map { "\($0.speakerName): \($0.text)" } ?? "\(group.memberBotIDs.count) members")
    }
}

private struct BotSidebarRow: View {
    let bot: Bot
    let isSelected: Bool
    @State private var isHovering = false

    private var preview: String? {
        let last = bot.displayMessages.last { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty }
        return (last?.text ?? bot.lastMessagePreview)?
            .replacingOccurrences(of: "\n", with: " ")
    }

    private var stamp: String? {
        bot.displayMessages.last { $0.role == .user || $0.role == .assistant }.map { Stamp.short($0.timestamp) }
    }

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(bot.name)
                        .font(.system(size: 17, weight: bot.hasUnread ? .semibold : .medium))
                        .lineLimit(1)
                    if !bot.tagline.isEmpty { RolePill(text: bot.tagline) }
                    Spacer(minLength: 4)
                    if let stamp {
                        Text(stamp).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if preview != nil || bot.hasUnread {
                HStack(spacing: 6) {
                    Text(preview ?? "")
                        .font(.system(size: 15))
                        .foregroundStyle(bot.hasUnread ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if bot.hasUnread {
                        Circle().fill(Theme.accent).frame(width: 9, height: 9)
                    }
                }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            isSelected ? Theme.selection : (isHovering ? Theme.selection.opacity(0.5) : .clear),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

struct JoinedGroupSidebarRow: View {
    let session: JoinedGroupSession
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 18))
                .foregroundStyle(.teal)
                .frame(width: 48, height: 48)
                .background(Theme.chip, in: Circle())
            Text(session.name).font(.system(size: 17, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if session.unreadCount > 0 {
                Text("\(session.unreadCount)")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.destructive, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}
