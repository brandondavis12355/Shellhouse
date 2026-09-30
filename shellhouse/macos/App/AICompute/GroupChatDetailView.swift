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

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                MemberAvatarStack(members: resolvedMembers)
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name).font(.title2)
                    HStack(spacing: 6) {
                        Text("\(group.memberBotIDs.count) member\(group.memberBotIDs.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if group.isShared {
                            Label("Shared with friends", systemImage: "person.2.wave.2")
                                .font(.caption2)
                                .foregroundStyle(.teal)
                        }
                    }
                }
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .imageScale(.large)
                .help("Group settings — rename, members, delete.")
            }

            if group.goal != nil {
                GroupGoalCard(
                    group: group,
                    ownerName: resolvedMembers.first(where: { $0.id == group.goal?.ownerBotID })?.name ?? "owner"
                )
            }

            GroupChatTranscriptView(
                messages: group.displayMessages,
                memberColors: Dictionary(uniqueKeysWithValues: resolvedMembers.map { ($0.id, $0.colorHex) }),
                mentionColors: Dictionary(uniqueKeysWithValues: resolvedMembers.map { ($0.name.lowercased(), $0.colorHex) })
            )

            BotStatusStrip(bots: resolvedMembers)

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
                                        index == highlightedSuggestionIndex ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 6)
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
                .padding(.vertical, 4)
            } else {
                HStack(alignment: .bottom) {
                    TextField("Message the group… (@mention a member to call on them)", text: $group.input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16))
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
                    Button("Send") { group.submitInput() }
                        .disabled(group.input.isEmpty)
                        .font(.system(size: 16))
                        .controlSize(.large)
                }
            }
        }
        .padding()
        // Lower than before (was 700/600) — see `BotDetailView`'s
        // matching comment: this fought the debug console's own
        // `HSplitView` divider, which can't shrink this side below
        // whatever it demands here.
        .frame(minWidth: 480, minHeight: 450)
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

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(members.prefix(4)) { bot in
                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: size)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
            if members.count > 4 {
                Text("+\(members.count - 4)")
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

    @State private var showingDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Group settings").font(.title2).bold()

            Text("Name").font(.caption).foregroundStyle(.secondary)
            TextField("Group name", text: $group.name).textFieldStyle(.roundedBorder)

            Text("Members (\(group.memberBotIDs.count)/\(GroupChatSession.maxMembers))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allBots) { bot in
                        let isMember = group.memberBotIDs.contains(bot.id)
                        Toggle(isOn: Binding(
                            get: { isMember },
                            set: { on in
                                if on { group.addMember(bot) } else { group.removeMember(bot.id) }
                            }
                        )) {
                            HStack {
                                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 22)
                                Text(bot.name)
                            }
                        }
                        // `memberBotIDs.count`, not `group.members.count` — the
                        // latter resolves through `botDirectory` (a plain,
                        // non-`@Observable` bridge), which doesn't reliably
                        // trigger a re-render on its own the moment
                        // `addMember`/`removeMember` mutate `memberBotIDs`.
                        .disabled(!isMember && group.memberBotIDs.count >= GroupChatSession.maxMembers)
                    }
                }
            }
            .frame(height: 200)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            Divider()
            GroupSharingSection(group: group)

            Divider()
            Text("Goals").font(.caption).foregroundStyle(.secondary)
            Picker("Coordinator (owns goals by default)", selection: $group.coordinatorBotID) {
                Text("Auto (manager-like role, else first member)").tag(String?.none)
                ForEach(allBots.filter { group.memberBotIDs.contains($0.id) }) { bot in
                    Text(bot.name).tag(String?.some(bot.id))
                }
            }
            Stepper("Pause after \(group.stallLimit) messages without progress", value: $group.stallLimit, in: 10...200, step: 5)
            Stepper("Auto-close unconfirmed goals after \(group.confirmTimeoutMinutes) min", value: $group.confirmTimeoutMinutes, in: 5...1440, step: 5)

            Divider()
            Button("Delete group…", role: .destructive) { showingDeleteConfirm = true }
                .foregroundStyle(.red)

            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
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
}
