import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentCore
import AgentUI

/// Sits inline in the chat flow — right after the transcript, right before
/// the input box — instead of a modal `.alert`. The agent is genuinely
/// paused (blocked on the continuation `onDecide` resumes) the whole time
/// this is visible, so it reads as "the agent is waiting for you, here,
/// in the conversation" rather than an interrupting system dialog.
struct ApprovalCard: View {
    let approval: Approval
    let onDecide: (AgentRuntime.ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.shield")
                    .imageScale(.large)
                    .foregroundStyle(.orange)
                Text("Approval needed").font(.title3)
            }
            Text(approval.toolName)
                .font(.system(.title3, design: .monospaced))
                .bold()
            Text(approval.argumentsSummary)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(6)
            HStack {
                if let binary = approval.alwaysAllowCandidate {
                    Menu("Always allow \"\(binary)\"…") {
                        Button("For this session") { onDecide(.approveAlwaysSession) }
                        Button("Always, on this Mac") { onDecide(.approveAlwaysGlobal) }
                    }
                    .fixedSize()
                    .font(.system(size: 14))
                }
                Spacer()
                Button("Deny") { onDecide(.deny) }
                    .font(.system(size: 14))
                Button("Approve") { onDecide(.approve) }
                    .keyboardShortcut(.defaultAction)
                    .font(.system(size: 14))
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4)))
        .cornerRadius(8)
    }
}

/// One bot's whole UI: computer panel + chat. `ContentView`'s sidebar shows
/// one of these for whichever bot is selected — everything here reads and
/// writes `bot`'s own state, so switching bots in the sidebar switches
/// every field, the transcript, and the live desktop view along with it.
/// Which "Messaged <name>…" thread `BotDetailView`'s sheet shows.
struct InterBotThreadTarget: Identifiable {
    let peerID: String
    let peerName: String
    var id: String { peerID }
}

struct BotDetailView: View {
    @Bindable var bot: Bot
    var onOpenSettings: () -> Void
    /// Off by default — the computer is a secondary, opt-in view now (see
    /// the desktop-icon button below), not something shown for every bot
    /// the moment you open it.
    @State private var showComputer = false
    /// When true, the chat pane is hidden entirely and the computer panel
    /// takes the space it would have used — for when the desktop itself is
    /// what needs room, not the conversation. Lives outside the chat
    /// `VStack` (in the always-visible header below) specifically so the
    /// button to turn this back off is never itself hidden by turning it on.
    @State private var computerExpanded = false
    /// Which inter-bot thread the "Messaged <name>…" sheet shows, if any —
    /// owned here rather than by the tapped message bubble (see
    /// `TranscriptView.onOpenInterBotThread`'s doc comment) so it can't be
    /// reset by an unrelated new message arriving in this same transcript.
    @State private var activeInterBotThread: InterBotThreadTarget?
    /// Which `@mention`/`/skill` (if either) is currently in progress —
    /// see `MentionAnchorTracker`'s doc comment for why this replaces
    /// the earlier whole-string heuristics (broke when the trigger
    /// character was typed into the middle of existing text) and the
    /// crash-prone `TextSelection`-based attempt before that.
    @State private var mentionTracker = MentionAnchorTracker(trigger: "@")
    /// No `requiresStartOfText` — behaves exactly like `mentionTracker`,
    /// triggerable anywhere `/` is typed (including right after an
    /// existing word, with no space), not just at the very start of the
    /// message. Note: `Bot.matchSlashCommand` (what actually expands a
    /// `/skill` into its instructions when the message is SENT) still
    /// only recognizes one leading the whole message — picking a
    /// suggestion mid-sentence inserts the text, but won't itself
    /// invoke the skill unless it ends up at the front.
    @State private var slashTracker = MentionAnchorTracker(trigger: "/")
    /// Index into whichever suggestion list is currently showing
    /// (`activeSuggestionList`) — Up/Down move it, Return commits it,
    /// and it's reset to 0 (top match highlighted) on every keystroke
    /// so it never points past the end of a freshly-narrowed list.
    @State private var highlightedSuggestionIndex = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 48)
                Text(bot.name).font(.title2)
                if !bot.tagline.isEmpty {
                    Text(bot.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: bot.colorHex).opacity(0.18), in: Capsule())
                }
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .imageScale(.large)
                .help("Bot settings — name, color, role, system prompt, skills, permissions, model, budgets.")
                Button("Export…") { exportTranscript() }
                    .disabled(bot.displayMessages.isEmpty)
                    .font(.system(size: 15))
                Button {
                    showComputer.toggle()
                    if !showComputer { computerExpanded = false }
                } label: {
                    Image(systemName: showComputer ? "desktopcomputer" : "desktopcomputer.and.arrow.down")
                }
                .imageScale(.large)
                .help(showComputer ? "Hide the computer panel" : "Show the computer panel")
                if showComputer {
                    Button {
                        computerExpanded.toggle()
                    } label: {
                        Image(systemName: computerExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                    }
                    .imageScale(.large)
                    .help(computerExpanded ? "Shrink the computer back down" : "Expand the computer over the chat")
                }
            }

            // `HSplitView` rather than a plain `HStack` — draggable divider
            // between the chat and the computer, so either side can be
            // resized by hand instead of the split being fixed at whatever
            // `minWidth` each pane happens to declare.
            HSplitView {
                if !computerExpanded {
                    VStack(spacing: 8) {
                        TranscriptView(
                            messages: bot.displayMessages, botName: bot.name, botColorHex: bot.colorHex, botID: bot.id,
                            mentionColors: mentionColors,
                            onOpenInterBotThread: { peerID, peerName in
                                activeInterBotThread = InterBotThreadTarget(peerID: peerID, peerName: peerName)
                            }
                        )

                        if let pending = bot.pendingApproval {
                            ApprovalCard(approval: pending.approval) { decision in
                                pending.continuation.resume(returning: decision)
                                bot.pendingApproval = nil
                                if decision == .approveAlwaysSession || decision == .approveAlwaysGlobal {
                                    Task { await bot.refreshPermissions() }
                                }
                            }
                        }

                        Group {
                            if bot.isProcessingMessage {
                                RespondingIndicatorView(name: bot.name, colorHex: bot.colorHex)
                            } else {
                                Text(bot.messageQueue.isEmpty ? bot.status : "\(bot.status) • \(bot.messageQueue.count) queued")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !bot.pendingAttachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(bot.pendingAttachments) { attachment in
                                        AttachmentChip(
                                            filename: attachment.url.lastPathComponent,
                                            isImage: attachment.isImage
                                        ) {
                                            bot.removeAttachment(attachment)
                                        }
                                    }
                                }
                            }
                        }

                        if !slashSuggestions.isEmpty {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(slashSuggestions.enumerated()), id: \.element.id) { index, skill in
                                        Button {
                                            insertSlashCommand(skill)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text("/\(skill.id)").font(.caption).bold().foregroundStyle(.purple)
                                                if !skill.description.isEmpty {
                                                    Text(skill.description).font(.caption2).foregroundStyle(.secondary)
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
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                        }

                        if !mentionSuggestions.isEmpty {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(mentionSuggestions.enumerated()), id: \.element.id) { index, other in
                                        Button { insertMention(other) } label: {
                                            HStack(spacing: 6) {
                                                BotAvatar(colorHex: other.colorHex, style: AvatarStyle(rawValue: other.avatarStyle) ?? .blob, size: 18)
                                                VStack(alignment: .leading, spacing: 0) {
                                                    Text(other.name).font(.caption).bold().foregroundStyle(Color(hex: other.colorHex))
                                                    if !other.tagline.isEmpty {
                                                        Text(other.tagline).font(.caption2).foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                // Slash suggestions take keyboard priority when both are
                                                // showing at once (see `activeSuggestionList`), so this
                                                // list only shows its own highlight when slash isn't active.
                                                (slashSuggestions.isEmpty && index == highlightedSuggestionIndex) ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 6)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 140)
                        }

                        HStack(alignment: .bottom) {
                            Button(action: pickAttachments) {
                                Image(systemName: "paperclip")
                            }
                            .imageScale(.large)
                            .disabled(bot.sandbox == nil)
                            .help("Attach a file or image to send alongside your message.")
                            TextField("Ask \(bot.name) to do something… (try / to invoke a skill)", text: $bot.input, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 16))
                                .disabled(bot.sandbox == nil)
                                .onSubmit { bot.submitInput() }
                                // Only intercepts Shift+Return, to insert a
                                // newline instead of submitting — anything
                                // else (including a plain Return) reports
                                // `.ignored` so the field's own default
                                // handling still runs and `.onSubmit` above
                                // still fires normally. `.onKeyPress` doesn't
                                // reliably intercept Return on a multi-line
                                // `axis: .vertical` field the way `.onSubmit`
                                // does, hence not handling both cases here.
                                // Pasting multi-line text already works with
                                // no extra handling — `axis: .vertical`
                                // grows the field for whatever's in
                                // `bot.input`, newlines included. Always
                                // appends at the end rather than at the
                                // caret — this project tried caret-aware
                                // insertion via `TextField`'s `selection:`
                                // binding (`TextSelection`) once already,
                                // for @mention detection too, and reverted
                                // both: it crashed ("String index range is
                                // out of bounds") in ways that weren't
                                // reliably fixable at the app level. Not
                                // worth the instability for either feature.
                                .onKeyPress(.upArrow) {
                                    guard let active = activeSuggestionList, active.count > 0 else { return .ignored }
                                    highlightedSuggestionIndex = (highlightedSuggestionIndex - 1 + active.count) % active.count
                                    return .handled
                                }
                                .onKeyPress(.downArrow) {
                                    guard let active = activeSuggestionList, active.count > 0 else { return .ignored }
                                    highlightedSuggestionIndex = (highlightedSuggestionIndex + 1) % active.count
                                    return .handled
                                }
                                .onKeyPress(.return, phases: .down) { press in
                                    // A suggestion popup showing takes priority over both
                                    // "send" and "newline" — Return commits the highlighted
                                    // suggestion instead, same as Slack/Discord-style menus.
                                    if let active = activeSuggestionList, active.count > 0, !press.modifiers.contains(.shift) {
                                        selectHighlightedSuggestion()
                                        return .handled
                                    }
                                    guard press.modifiers.contains(.shift) else { return .ignored }
                                    bot.input += "\n"
                                    return .handled
                                }
                                .onChange(of: bot.input) { old, new in
                                    mentionTracker.handleChange(old: old, new: new)
                                    slashTracker.handleChange(old: old, new: new)
                                    highlightedSuggestionIndex = 0
                                }
                            if bot.isProcessingMessage {
                                Button("Stop", role: .destructive) { bot.stop() }
                                    .font(.system(size: 16))
                                    .controlSize(.large)
                                    .help("Stops the message currently being processed and clears anything still queued behind it.")
                            }
                            Button(bot.isBusy ? "Queue" : "Send") { bot.submitInput() }
                                .disabled((bot.input.isEmpty && bot.pendingAttachments.isEmpty) || bot.sandbox == nil)
                                .font(.system(size: 16))
                                .controlSize(.large)
                        }
                    }
                    .frame(minWidth: 360)
                }

                if showComputer {
                    ComputerPanel(state: bot.state) { error in
                        bot.status = "WKWebView load error: \(error)"
                    }
                    .frame(minWidth: computerExpanded ? nil : 480)
                }
            }
        }
        .padding()
        // Must be >= this view's own inner `HSplitView` minimum (chat's
        // 360 + the computer panel's 480 = 840 when both are visible) —
        // a lower outer minimum (560 was tried, and briefly shipped)
        // CONTRADICTS that inner minimum the moment the computer panel
        // opens, and AppKit doesn't just clamp to the larger one: it
        // keeps re-resolving the conflict every layout pass until its own
        // runaway-layout circuit breaker trips and crashes the app
        // (`NSGenericException`: "already had more Update Constraints in
        // Window passes than there are views in the window"). Lower than
        // the ORIGINAL 1000 is still fine — it just has to stay >= 840.
        .frame(minWidth: 840, minHeight: 500)
        // "Read" just means "this bot's conversation is the one on screen
        // right now" — covers both switching to it and it getting a new
        // message while it's already the one open.
        .onAppear { bot.markRead() }
        .onChange(of: bot.displayMessages.count) { _, _ in bot.markRead() }
        .sheet(item: $activeInterBotThread) { thread in
            InterBotThreadView(
                myBotID: bot.id, myBotName: bot.name, myBotColorHex: bot.colorHex,
                peerID: thread.peerID, peerName: thread.peerName
            )
        }
    }

    private func exportTranscript() {
        let text = bot.exportTranscriptText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(bot.name)-transcript-\(Int(Date().timeIntervalSince1970)).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Skills matching whatever's typed after a leading `/`, so the field
    /// works as a discoverable command list rather than something you have
    /// to already know a skill's exact id to use. Only while still typing
    /// the command token itself (no space yet) — once there's a space, the
    /// rest is the actual message and suggestions would just be noise.
    private var slashSuggestions: [Skill] {
        guard let query = slashTracker.query(in: bot.input) else { return [] }
        let candidates = query.isEmpty
            ? bot.availableSkills
            : bot.availableSkills.filter { $0.id.lowercased().hasPrefix(query) }
        // The full list, most-used first — the suggestion list scrolls
        // (see its vertical `ScrollView` above), so there's no need to
        // truncate down to a "top N" default anymore.
        return SlashCommandUsage.suggestions(from: candidates, limit: candidates.count)
    }

    private func insertSlashCommand(_ skill: Skill) {
        guard let range = slashTracker.replacementRange(in: bot.input) else { return }
        bot.input.replaceSubrange(range, with: "/\(skill.id) ")
        slashTracker.reset()
    }

    /// Every other bot on this Mac — who `bot` could @mention to delegate
    /// to via `message_bot` (see `Bot.fullSystemPrompt`'s "Other bots"
    /// section). Read fresh each time rather than cached, same reasoning
    /// as `GroupChatSession.members`.
    private var otherBots: [Bot] {
        bot.botDirectory.allBots().filter { $0.id != bot.id }
    }

    private var mentionColors: [String: String] {
        Dictionary(uniqueKeysWithValues: otherBots.map { ($0.name.lowercased(), $0.colorHex) })
    }

    /// Same "still typing the token itself" gate as `slashSuggestions` —
    /// matches on whatever's after the most recently TYPED (not just
    /// found) unfinished `@`, tracked via `mentionTracker` so `@` works
    /// correctly even typed into the middle of existing text.
    private var mentionSuggestions: [Bot] {
        guard let query = mentionTracker.query(in: bot.input) else { return [] }
        return otherBots.filter { $0.name.lowercased().hasPrefix(query) }
    }

    private func insertMention(_ other: Bot) {
        guard let range = mentionTracker.replacementRange(in: bot.input) else { return }
        bot.input.replaceSubrange(range, with: "@\(other.name) ")
        mentionTracker.reset()
    }

    /// Which suggestion popup (if either) keyboard nav currently acts
    /// on. Slash takes priority when both a `/` and an unfinished `@`
    /// are in progress at once — a rare case, but the two boxes render
    /// independently, so nav needs to pick exactly one to control.
    private enum ActiveSuggestionList {
        case slash([Skill])
        case mention([Bot])

        var count: Int {
            switch self {
            case .slash(let items): return items.count
            case .mention(let items): return items.count
            }
        }
    }

    private var activeSuggestionList: ActiveSuggestionList? {
        if !slashSuggestions.isEmpty { return .slash(slashSuggestions) }
        if !mentionSuggestions.isEmpty { return .mention(mentionSuggestions) }
        return nil
    }

    private func selectHighlightedSuggestion() {
        guard let active = activeSuggestionList, active.count > 0 else { return }
        let index = min(highlightedSuggestionIndex, active.count - 1)
        switch active {
        case .slash(let items): insertSlashCommand(items[index])
        case .mention(let items): insertMention(items[index])
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            bot.addAttachments(panel.urls)
        }
    }
}

/// One picked-but-not-sent file, shown above the input row before you hit
/// Send, and (via `MessageBubble`'s own use of the same look) below a
/// message's text once it's actually been sent.
struct AttachmentChip: View {
    let filename: String
    let isImage: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isImage ? "photo" : "doc")
                .font(.caption)
            Text(filename)
                .font(.caption)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}
