import AgentCore
import SwiftUI

struct GroupChatDetailView: View {
    @Bindable var group: GroupChatSession
    /// The sidebar's live bot list, passed down directly rather than
    /// resolved via `group.members` (which goes through `botDirectory`, a
    /// plain non-`@Observable` bridge that doesn't reliably re-render this
    /// view on its own). Same pattern `GroupChatSettingsView` already
    /// uses. See `resolvedMembers`.
    let allBots: [Bot]
    var onOpenSettings: () -> Void

    /// `group.memberBotIDs`, resolved against `allBots` directly instead
    /// of through `group.members`/`botDirectory` — this is what actually
    /// stays reactive to both `memberBotIDs` changes (Settings toggles)
    /// and `allBots` changes (a bot added/removed elsewhere), since both
    /// are read as plain values right here in this view's own body.
    private func exportTranscript() {
        let lines = group.displayMessages.map { message in
            GroupTranscriptExport.Line(
                time: message.timestamp, speaker: message.speakerName, text: message.text,
                kind: message.isSystem == true ? .notice : message.externalUserID != nil ? .friend : message.speakerBotID != nil ? .bot : .user
            )
        }
        let text = GroupTranscriptExport.markdown(groupName: group.name, members: ["You"] + resolvedMembers.map(\.name), lines: lines)
        saveTranscript(text, suggestedName: GroupTranscriptExport.fileName(groupName: group.name))
    }

    private var resolvedMembers: [Bot] {
        let byID = Dictionary(uniqueKeysWithValues: allBots.map { ($0.id, $0) })
        return group.memberBotIDs.compactMap { byID[$0] }
    }

    /// Which `@mention` is currently in progress — see
    /// `MentionAnchorTracker`'s doc comment.
    @State private var mentionTracker = MentionAnchorTracker(trigger: "@")
    /// Index into `mentionSuggestionItems` (the "Everyone" row, when
    /// shown, is index 0) — Up/Down move it, Return commits it, reset
    /// to 0 on every keystroke. See `BotDetailView.highlightedSuggestionIndex`.
    @State private var highlightedSuggestionIndex = 0
    /// The goal lives behind a top-bar button instead of a banner over the chat.
    @State private var showGoal = false

    var body: some View {
        VStack(spacing: 0) {
            ChatTopBar {
                SidebarToggleButton()
            } center: {
                HeaderPill(title: group.name, help: "Group settings — rename, members, delete.", action: onOpenSettings) {
                    MemberAvatarStack(members: resolvedMembers, size: 28)
                }
            } trailing: {
                if group.isShared {
                    Image(systemName: "person.2.wave.2")
                        .foregroundStyle(.teal)
                        .help("Shared with friends")
                }
                if let goal = group.goal {
                    GlassCircleButton(systemName: "target", help: "Goal · \(goal.doneCount)/\(goal.steps.count) steps") { showGoal.toggle() }
                        .overlay(alignment: .topTrailing) {
                            if goal.isLive {
                                Circle().fill(Theme.accent).frame(width: 9, height: 9).offset(x: 2, y: -2)
                            }
                        }
                        .popover(isPresented: $showGoal, arrowEdge: .bottom) {
                            GroupGoalCard(
                                group: group,
                                ownerName: resolvedMembers.first(where: { $0.id == goal.ownerBotID })?.name ?? "owner",
                                inPopover: true
                            )
                            .padding(14)
                            .frame(width: 400)
                        }
                }
                GlassCircleMenu(help: "More") {
                    Button("Export transcript…") { exportTranscript() }
                        .disabled(group.displayMessages.isEmpty)
                }
                GlassCircleButton(systemName: "info", help: "Group settings — rename, members, delete.", action: onOpenSettings)
            }

            GroupChatTranscriptView(
                messages: group.displayMessages,
                memberColors: Dictionary(uniqueKeysWithValues: resolvedMembers.map { ($0.id, $0.colorHex) }),
                memberStyles: Dictionary(uniqueKeysWithValues: resolvedMembers.map { ($0.id, $0.avatarStyle) }),
                mentionColors: Dictionary(uniqueKeysWithValues: resolvedMembers.map { ($0.name.lowercased(), $0.colorHex) }),
                drafts: resolvedMembers.compactMap { member in
                    group.liveDrafts[member.id].map { GroupMessage(id: "draft-\(member.id)", speakerBotID: member.id, speakerName: member.name, text: $0) }
                }
            )
            .padding(.horizontal, 20)

            BotStatusStrip(bots: resolvedMembers)
                .padding(.horizontal, 24)
                .padding(.top, 6)

            if !mentionSuggestionItems.isEmpty {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(mentionSuggestionItems.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    select(item)
                                } label: {
                                    Group {
                                        switch item {
                                        case .everyone:
                                            // Gray, same as `@everyone`'s pill color in the
                                            // transcript (`MentionPillText`) — it addresses
                                            // every member at once, not one bot's own color.
                                            HStack(spacing: 6) {
                                                Image(systemName: "person.3.fill")
                                                    .foregroundStyle(.gray)
                                                    .frame(width: 18)
                                                Text("Everyone").font(.caption).bold().foregroundStyle(.gray)
                                                Text("— calls on every member").font(.caption2).foregroundStyle(.secondary)
                                            }
                                        case .bot(let bot):
                                            HStack(spacing: 6) {
                                                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 18)
                                                Text(bot.name).font(.caption).bold().foregroundStyle(Color(hex: bot.colorHex))
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        index == highlightedSuggestionIndex ? Theme.selection : Theme.card,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    // See `BotDetailView`'s matching comment — keeps the
                    // highlighted row in view as the arrow keys move it
                    // past whatever's currently scrolled into frame.
                    .onChange(of: highlightedSuggestionIndex) { _, newIndex in
                        scrollProxy.scrollTo(newIndex, anchor: nil)
                    }
                }
            }

            if group.memberBotIDs.isEmpty {
                // `memberBotIDs.isEmpty`, not `group.members.isEmpty` — the
                // latter resolves through `botDirectory` (a plain, non-
                // `@Observable` bridge) and doesn't reliably trigger a
                // re-render the moment `addMember` mutates `memberBotIDs`
                // from the settings sheet. This also explains why messaging
                // is blocked, rather than a compose box that just looks
                // broken.
                HStack {
                    Text("This group has no members yet. Add some to start messaging.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add members…", action: onOpenSettings)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            } else {
                ComposerPill {
                    TextField("Message the group", text: $group.input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .lineLimit(1...8)
                        .help("@mention a member to call on them. Shift+Return for a new line.")
                        .onSubmit { group.submitInput() }
                        // Only intercepts Shift+Return, to insert a
                        // newline instead of submitting — see
                        // `BotDetailView`'s matching field for why this
                        // doesn't also handle plain Return, and why this
                        // always appends at the end rather than at the
                        // caret (reverted caret-aware editing here too,
                        // same crash).
                        .onKeyPress(.upArrow) {
                            guard !mentionSuggestionItems.isEmpty else { return .ignored }
                            highlightedSuggestionIndex = (highlightedSuggestionIndex - 1 + mentionSuggestionItems.count) % mentionSuggestionItems.count
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            guard !mentionSuggestionItems.isEmpty else { return .ignored }
                            highlightedSuggestionIndex = (highlightedSuggestionIndex + 1) % mentionSuggestionItems.count
                            return .handled
                        }
                        .onKeyPress(.return, phases: .down) { press in
                            if !mentionSuggestionItems.isEmpty, !press.modifiers.contains(.shift) {
                                selectHighlightedSuggestion()
                                return .handled
                            }
                            guard press.modifiers.contains(.shift) else { return .ignored }
                            group.input += "\n"
                            return .handled
                        }
                        .onChange(of: group.input) { old, new in
                            mentionTracker.handleChange(old: old, new: new)
                            highlightedSuggestionIndex = 0
                        }
                    // Deliberately NOT disabled while `group.isBusy` — see
                    // `GroupChatSession.submitInput`'s doc comment. Typing
                    // something else in while a member is mid-response
                    // should still land in the transcript right away, not
                    // wait for that response to finish first.

                } actions: {
                    SendCircleButton(isEnabled: !group.input.isEmpty, help: "Send") { group.submitInput() }
                }
                .frame(maxWidth: Theme.chatColumnWidth)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.bg)
        // Lower than before (was 700/600) — see `BotDetailView`'s
        // matching comment: this fought the debug console's own
        // `HSplitView` divider, which can't shrink this side below
        // whatever it demands here.
        .frame(minWidth: 400, minHeight: 450)
    }

    /// Members matching whatever's typed after the most recent unfinished
    /// `@` token — same "still typing the token itself" gate as
    /// `BotDetailView.slashSuggestions`, so this disappears the moment a
    /// space ends the mention rather than lingering over the rest of the
    /// message.
    private var mentionSuggestions: [Bot] {
        guard let mentionQuery else { return [] }
        return resolvedMembers.filter { $0.name.lowercased().hasPrefix(mentionQuery) }
    }

    /// "everyone" itself is offered as a suggestion the same way a real
    /// member's name is — only makes sense with 2+ members to actually
    /// call on at once.
    private var showsEveryoneSuggestion: Bool {
        guard let mentionQuery, resolvedMembers.count > 1 else { return false }
        return "everyone".hasPrefix(mentionQuery)
    }

    /// Same "still typing the token itself" gate as `BotDetailView`'s
    /// suggestions — matches on whatever's after the most recently TYPED
    /// (not just found) unfinished `@`, via `mentionTracker`.
    private var mentionQuery: String? {
        mentionTracker.query(in: group.input)
    }

    private func insertMention(_ bot: Bot) {
        insertMentionText(bot.name)
    }

    private func insertEveryoneMention() {
        insertMentionText("everyone")
    }

    private func insertMentionText(_ name: String) {
        guard let range = mentionTracker.replacementRange(in: group.input) else { return }
        group.input.replaceSubrange(range, with: "@\(name) ")
        mentionTracker.reset()
    }

    /// Unifies the synthetic "Everyone" row with the real per-member
    /// rows into one navigable list — "Everyone" is index 0 when it's
    /// shown, so Up/Down/Return act on a single ordered sequence
    /// instead of two independent pieces of state.
    private enum MentionSuggestionItem: Identifiable {
        case everyone
        case bot(Bot)

        var id: String {
            switch self {
            case .everyone: return "__everyone__"
            case .bot(let bot): return bot.id
            }
        }
    }

    private var mentionSuggestionItems: [MentionSuggestionItem] {
        var items: [MentionSuggestionItem] = []
        if showsEveryoneSuggestion { items.append(.everyone) }
        items.append(contentsOf: mentionSuggestions.map { .bot($0) })
        return items
    }

    private func select(_ item: MentionSuggestionItem) {
        switch item {
        case .everyone: insertEveryoneMention()
        case .bot(let bot): insertMention(bot)
        }
    }

    private func selectHighlightedSuggestion() {
        let items = mentionSuggestionItems
        guard !items.isEmpty else { return }
        select(items[min(highlightedSuggestionIndex, items.count - 1)])
    }
}

/// Overlapping member avatars, like the reference app's group-chat icon —
/// up to 4 shown, "+N" beyond that.
struct MemberAvatarStack: View {
    let members: [Bot]
    var size: CGFloat = 34
    var maxShown = 4

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(members.prefix(maxShown)) { bot in
                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: size)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
            if members.count > maxShown {
                Text("+\(members.count - maxShown)")
                    .font(.caption2).bold()
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.2), in: Circle())
            }
        }
    }
}

/// Rename, add/remove members (capped at 6), delete — the group-chat
/// counterpart to `BotSettingsView`.
struct GroupChatSettingsView: View {
    @Bindable var group: GroupChatSession
    let allBots: [Bot]
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    // Edits are made on a draft and only applied by Save; Cancel (or Esc)
    // throws them away. (Sharing and Delete act immediately — they're
    // actions on the relay / the group itself, not fields.)
    @State private var name = ""
    @State private var memberIDs: [String] = []
    @State private var coordinatorBotID: String?
    @State private var stallLimit = GroupGoal.defaultStallLimit
    @State private var confirmTimeoutMinutes = 60
    @State private var showingDeleteConfirm = false
    @State private var showingClearConfirm = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasChanges: Bool {
        trimmedName != group.name || memberIDs != group.memberBotIDs || coordinatorBotID != group.coordinatorBotID
            || stallLimit != group.stallLimit || confirmTimeoutMinutes != group.confirmTimeoutMinutes
    }

    private var selectedMembers: [Bot] {
        memberIDs.compactMap { id in allBots.first { $0.id == id } }
    }

    var body: some View {
        SheetScaffold(title: "Group settings", onClose: { dismiss() }, content: {
            VStack(alignment: .leading, spacing: 0) {
                AvatarCluster(members: selectedMembers, size: 150)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 18)

                Card {
                    TextField("Group name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 16)
                }

                SectionLabel("Members (\(memberIDs.count)/\(GroupChatSession.maxMembers))")
                Card {
                    ForEach(Array(allBots.enumerated()), id: \.element.id) { index, bot in
                        if index > 0 { CardDivider(inset: 58) }
                        let isMember = memberIDs.contains(bot.id)
                        HStack(spacing: 12) {
                            BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(bot.name).font(.system(size: 17))
                                Text(bot.handle.map { "Own Linux VM · \($0.id)" } ?? "Own Linux VM · not running")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { isMember },
                                set: { on in
                                    if on, !memberIDs.contains(bot.id) { memberIDs.append(bot.id) }
                                    if !on { memberIDs.removeAll { $0 == bot.id } }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(Theme.positive)
                            .disabled(!isMember && memberIDs.count >= GroupChatSession.maxMembers)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                }
                SectionFooter("Group Chats can have up to \(GroupChatSession.maxMembers) members.")

                SectionLabel("Goals")
                Card {
                    SettingRow("Coordinator", subtitle: "Owns goals by default") {
                        Picker("", selection: $coordinatorBotID) {
                            Text("Auto").tag(String?.none)
                            ForEach(allBots.filter { memberIDs.contains($0.id) }) { bot in
                                Text(bot.name).tag(String?.some(bot.id))
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    CardDivider()
                    SettingRow("Pause after \(stallLimit) messages without progress") {
                        Stepper("", value: $stallLimit, in: 10...200, step: 5).labelsHidden()
                    }
                    CardDivider()
                    SettingRow("Auto-close unconfirmed goals after \(confirmTimeoutMinutes) min") {
                        Stepper("", value: $confirmTimeoutMinutes, in: 5...1440, step: 5).labelsHidden()
                    }
                }

                SectionLabel("Friends")
                Card {
                    GroupSharingSection(group: group)
                        .padding(16)
                }
                SectionFooter("Sharing takes effect immediately, without Save.")

                Card {
                    Button { showingClearConfirm = true } label: {
                        SettingRow(
                            "Clear conversation…", subtitle: group.isBusy ? "Wait for the members to finish first." : nil,
                            titleColor: Theme.destructive
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(group.isBusy || group.displayMessages.isEmpty)
                    .opacity(group.isBusy || group.displayMessages.isEmpty ? 0.45 : 1)
                    CardDivider()
                    Button { showingDeleteConfirm = true } label: {
                        SettingRow("Delete group…", titleColor: Theme.destructive)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 22)
            }
        }, footer: {
            SheetFooter {
                if hasChanges { Text("Unsaved changes").font(.system(size: 13)).foregroundStyle(Theme.warning) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || trimmedName.isEmpty)
            }
        })
        .frame(width: 520, height: 700)
        .onAppear(perform: loadDraft)
        .alert("Clear this conversation?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { group.clearConversation() }
        } message: {
            Text("Permanently deletes this group's messages on this Mac. Members, settings and any goal are kept."
                + (group.isShared ? " Friends keep the copy they already have: messages already shared stay on the relay." : ""))
        }
        .alert("Delete \(group.name)?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("Permanently deletes this group and its shared transcript. The member bots themselves aren't affected.")
        }
    }

    private func loadDraft() {
        name = group.name
        memberIDs = group.memberBotIDs
        coordinatorBotID = group.coordinatorBotID
        stallLimit = group.stallLimit
        confirmTimeoutMinutes = group.confirmTimeoutMinutes
    }

    private func save() {
        group.name = trimmedName
        let current = group.memberBotIDs
        for id in current where !memberIDs.contains(id) { group.removeMember(id) }
        for id in memberIDs where !current.contains(id) {
            if let bot = allBots.first(where: { $0.id == id }) { group.addMember(bot) }
        }
        // A coordinator who is no longer a member falls back to Auto.
        group.coordinatorBotID = coordinatorBotID.flatMap { memberIDs.contains($0) ? $0 : nil }
        group.stallLimit = stallLimit
        group.confirmTimeoutMinutes = confirmTimeoutMinutes
        dismiss()
    }
}
