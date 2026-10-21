import SwiftUI
import LocalAuthentication
import AppKit
import UniformTypeIdentifiers
import AgentCore
import AgentUI

/// A bot asking for credentials (`request_credentials`) or a sign-in (`request_login`). Secret fields are
/// secure text fields (macOS turns on Secure Keyboard Entry while one has focus); values go straight to the
/// Keychain, the bot only ever learns their names, and nothing is saved until the person at the Mac confirms
/// with Touch ID or their password. Typed values are dropped whenever the card goes away.
struct CredentialRequestCard: View {
    let botName: String
    let pending: PendingCredentialRequest
    let onAnswer: ([String: String]?) -> Void
    @State private var values: [String: String] = [:]
    @State private var authError: String?
    @State private var authenticating = false

    private var fields: [CredentialRequest.Field] { pending.request.fields }

    private func isSaved(_ field: CredentialRequest.Field) -> Bool { pending.savedNames.contains(field.name) }

    private var canSubmit: Bool {
        !authenticating && fields.allSatisfy { !(values[$0.name] ?? "").isEmpty || isSaved($0) }
    }

    private var title: String {
        if case .login(let service, _) = pending.request.kind { return "\(botName) wants to sign in to \(service)" }
        return "\(botName) needs credentials"
    }

    private var site: String? {
        if case .login(_, let site) = pending.request.kind { return site }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: site != nil || isLogin ? "person.badge.key.fill" : "key.fill")
                    .imageScale(.large)
                    .foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 17, weight: .semibold))
            }
            if let site {
                Label(site, systemImage: "globe")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(botName) says:").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(pending.request.reason).font(.system(size: 14)).textSelection(.enabled)
            }
            if pending.untrusted {
                Label("\(botName) has read untrusted content (a web page, a download or someone else's message), which could have "
                      + "prompted this. Only continue if you asked it to do this.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warning)
            }
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(field.label).font(.system(size: 13, weight: .medium))
                        Text(field.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    let binding = Binding(get: { values[field.name] ?? "" }, set: { values[field.name] = $0; authError = nil })
                    let prompt = isSaved(field) ? "Saved — leave blank to keep it" : field.label
                    Group {
                        if field.secret {
                            SecureField(prompt, text: binding)
                        } else {
                            TextField(prompt, text: binding)
                                .autocorrectionDisabled()
                        }
                    }
                    .textContentType(field.secret ? .password : .username)
                    .themedField()
                    .onSubmit { if canSubmit { authenticateThenSubmit() } }
                }
            }
            Label("Saved only in this Mac's Keychain (not synced or backed up). \(botName) can use "
                  + (isLogin ? "the password" : "secrets") + " but never sees them. You'll confirm with Touch ID or your password.",
                  systemImage: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let authError {
                Text(authError).font(.system(size: 12)).foregroundStyle(Theme.destructive)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Decline") { wipe(); onAnswer(nil) }
                Button("Save and continue") { authenticateThenSubmit() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onDisappear { wipe() }
    }

    private var isLogin: Bool {
        if case .login = pending.request.kind { return true }
        return false
    }

    /// Device-owner authentication first: whatever filled the form, a person at this Mac decides it's saved.
    private func authenticateThenSubmit() {
        guard canSubmit else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authError = "Couldn't confirm it's you (\(error?.localizedDescription ?? "no authentication available")), so nothing was saved."
            return
        }
        authenticating = true
        let what = site.map { "save sign-in details for \($0)" } ?? "save credentials for \(botName)"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: what) { ok, failure in
            DispatchQueue.main.async {
                authenticating = false
                guard ok else {
                    authError = "Not saved: " + (failure?.localizedDescription ?? "authentication was cancelled") + "."
                    return
                }
                let answer = values
                wipe()
                onAnswer(answer)
            }
        }
    }

    /// Drops the typed values from the view's state (Swift can't zero a String's memory; this keeps them from lingering).
    private func wipe() { values = [:] }
}

/// Sits inline in the chat flow — right after the transcript, right before
/// the input box — instead of a modal `.alert`. The agent is genuinely
/// paused (blocked on the continuation `onDecide` resumes) the whole time
/// this is visible, so it reads as "the agent is waiting for you, here,
/// in the conversation" rather than an interrupting system dialog.
struct ApprovalCard: View {
    let approval: Approval
    let onDecide: (AgentRuntime.ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .imageScale(.large)
                    .foregroundStyle(Theme.warning)
                Text("Approval needed").font(.system(size: 17, weight: .semibold))
            }
            Text(approval.toolName)
                .font(.system(size: 15, design: .monospaced))
                .bold()
            if approval.strict {
                Label("Needs your explicit OK every time — no \"always allow\"", systemImage: "hand.raised.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.destructive)
            }
            if !approval.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(approval.reasons.prefix(4).enumerated()), id: \.offset) { _, reason in
                        Text("• \(reason)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            if approval.untrusted {
                Text(approval.sources.isEmpty
                    ? "Untrusted content is part of this conversation, so this needs your approval every time."
                    : "This chat has read untrusted content (\(approval.sources.joined(separator: ", "))), so this needs your approval every time.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warning)
            }
            Text(approval.argumentsSummary)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(6)
            if let digest = approval.argsDigest {
                Text("ref \(digest) · this approval covers exactly this action")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if let binary = approval.alwaysAllowCandidate {
                    Menu("Always allow \"\(binary)\"…") {
                        Button("For this session") { onDecide(.approveAlwaysSession) }
                        Button("Always, on this Mac") { onDecide(.approveAlwaysGlobal) }
                    }
                    .fixedSize()
                    .font(.system(size: 14))
                }
                if approval.toolName == "run_shell", !approval.untrusted, !approval.strict {
                    Menu("Allow all shell commands…") {
                        Button("This bot, this session") { onDecide(.approveAllShellThisBotSession) }
                        Button("This bot, always") { onDecide(.approveAllShellThisBotAlways) }
                    }
                    .fixedSize()
                    .font(.system(size: 14))
                }
                Spacer()
                Button("Deny") { onDecide(.deny) }
                Button("Approve") { onDecide(.approve) }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1))
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
    @State private var editingMessage: MessageEdit?
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
        VStack(spacing: 0) {
            ChatTopBar {
                SidebarToggleButton()
            } center: {
                HeaderPill(
                    title: bot.name,
                    help: "Bot settings — name, color, role, system prompt, skills, permissions, model, budgets.",
                    action: onOpenSettings
                ) {
                    BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 30)
                }
            } trailing: {
                if showComputer {
                    GlassCircleButton(
                        systemName: computerExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        help: computerExpanded ? "Shrink the computer back down" : "Expand the computer over the chat"
                    ) { computerExpanded.toggle() }
                }
                GlassCircleButton(
                    systemName: "desktopcomputer",
                    help: showComputer ? "Hide the computer panel" : "Show the computer panel"
                ) {
                    showComputer.toggle()
                    if !showComputer { computerExpanded = false }
                }
                GlassCircleMenu(help: "More") {
                    Button("Bot settings…", action: onOpenSettings)
                    Button("Export transcript…") { exportTranscript() }
                        .disabled(bot.displayMessages.isEmpty)
                }
            }

            // `HSplitView` rather than a plain `HStack` — draggable divider
            // between the chat and the computer, so either side can be
            // resized by hand instead of the split being fixed at whatever
            // `minWidth` each pane happens to declare.
            HSplitView {
                if !computerExpanded {
                    VStack(spacing: 10) {
                        TranscriptView(
                            messages: bot.displayMessages, botName: bot.name, botColorHex: bot.colorHex, botID: bot.id,
                            mentionColors: mentionColors,
                            peerAvatarStyles: Dictionary(uniqueKeysWithValues: otherBots.map { ($0.name.lowercased(), $0.avatarStyle) }),
                            onOpenInterBotThread: { peerID, peerName in
                                activeInterBotThread = InterBotThreadTarget(peerID: peerID, peerName: peerName)
                            },
                            onEdit: bot.canEditMessages ? { message in editingMessage = MessageEdit(id: message.id.uuidString, text: message.text) } : nil,
                            onDelete: bot.canEditMessages ? { message in bot.deleteMessage(id: message.id) } : nil,
                            isWorking: bot.isProcessingMessage,
                            liveStatus: bot.status
                        )
                        .sheet(item: $editingMessage) { edit in
                            MessageEditSheet(edit: edit) { text in
                                if let id = UUID(uuidString: edit.id) { bot.editMessage(id: id, text: text) }
                            }
                        }

                        VStack(spacing: 10) {
                        // Cards glide in and out instead of popping (see `AnyTransition.cardArrival`).
                        VStack(spacing: 10) {
                            if let pending = bot.pendingApproval {
                                ApprovalCard(approval: pending.approval) { decision in
                                    pending.continuation.resume(returning: decision)
                                    bot.pendingApproval = nil
                                    if decision == .approveAlwaysSession || decision == .approveAlwaysGlobal {
                                        Task { await bot.refreshPermissions() }
                                    }
                                }
                                .id(pending.id)
                                .transition(.cardArrival)
                            }

                            if let pending = bot.pendingCredentialRequest {
                                CredentialRequestCard(botName: bot.name, pending: pending) { values in
                                    bot.answerCredentialRequest(values)
                                }
                                .id(pending.id)
                                .transition(.cardArrival)
                            }

                            if !bot.pendingReview.isEmpty {
                                PendingReviewCard(bot: bot)
                                    .transition(.cardArrival)
                            }
                        }
                        .motion(Motion.settle, value: bot.pendingApproval?.id)
                        .motion(Motion.settle, value: bot.pendingCredentialRequest?.id)
                        .motion(Motion.settle, value: bot.pendingReview.count)

                        OwnBotStatusView(bot: bot)
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
                            ScrollViewReader { scrollProxy in
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
                                                    index == highlightedSuggestionIndex ? Theme.selection : Theme.card,
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .id(index)
                                        }
                                    }
                                }
                                .frame(maxHeight: 180)
                                // Keeps the highlighted row in view as the
                                // arrow keys move it past whatever's
                                // currently scrolled into frame — without
                                // this, moving the highlight past the
                                // visible ~180pt just looked like nothing
                                // was happening.
                                .onChange(of: highlightedSuggestionIndex) { _, newIndex in
                                    scrollProxy.scrollTo(newIndex, anchor: nil)
                                }
                            }
                        }

                        if !mentionSuggestions.isEmpty {
                            ScrollViewReader { scrollProxy in
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
                                                    (slashSuggestions.isEmpty && index == highlightedSuggestionIndex) ? Theme.selection : Theme.card,
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .id(index)
                                        }
                                    }
                                }
                                .frame(maxHeight: 140)
                                .onChange(of: highlightedSuggestionIndex) { _, newIndex in
                                    guard slashSuggestions.isEmpty else { return }
                                    scrollProxy.scrollTo(newIndex, anchor: nil)
                                }
                            }
                        }

                        HStack(alignment: .bottom, spacing: 10) {
                            Button(action: pickAttachments) {
                                GlassCircleLabel(systemName: "plus", size: 48)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .disabled(bot.sandbox == nil)
                            .opacity(bot.sandbox == nil ? 0.4 : 1)
                            .help("Attach a file or image to send alongside your message.")
                            ComposerPill {
                                TextField("Ask \(bot.name)", text: $bot.input, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 16))
                                    .lineLimit(1...8)
                                    .disabled(bot.sandbox == nil)
                                    .help("Try / to invoke a skill, or @ to mention another bot. Shift+Return for a new line.")
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
                            } actions: {
                                if bot.isProcessingMessage {
                                    StopCircleButton(help: "Stops the message currently being processed and clears anything still queued behind it.") { bot.stop() }
                                }
                                SendCircleButton(
                                    isEnabled: !((bot.input.isEmpty && bot.pendingAttachments.isEmpty) || bot.sandbox == nil),
                                    help: bot.isBusy ? "Queue this message" : "Send"
                                ) { bot.submitInput() }
                            }
                        }
                        .padding(.bottom, 14)
                        }
                        .frame(maxWidth: Theme.chatColumnWidth)
                    }
                    .padding(.horizontal, 20)
                    .frame(minWidth: 360)
                }

                if showComputer {
                    ComputerPanel(state: bot.state, pointer: bot.agentPointer) { error in
                        bot.status = "WKWebView load error: \(error)"
                    }
                    .frame(minWidth: computerExpanded ? nil : 480)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
                    .padding(.leading, computerExpanded ? 16 : 6)
                }
            }
        }
        .background(Theme.bg)
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
        // Tracks exactly what the inner split needs: chat alone is 360 + padding; with the
        // computer panel open beside it, chat 360 + panel 480 (see above). Never lower than the inner minimum.
        .frame(minWidth: (showComputer && !computerExpanded) ? 840 : 400, minHeight: 500)
        // "Read" just means "this bot's conversation is the one on screen
        // right now" — covers both switching to it and it getting a new
        // message while it's already the one open.
        .onAppear { bot.markRead(); bot.refreshPendingReview() }
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
        .background(Theme.chip, in: Capsule())
    }
}

/// Memories / routines the agent tried to save after reading untrusted content.
/// Nothing here has taken effect; the user decides.
struct PendingReviewCard: View {
    let bot: Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill").foregroundStyle(Theme.warning)
                Text("Held for your review (\(bot.pendingReview.count))").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Trust this chat again") { bot.clearUntrustedFlag() }
                    .buttonStyle(.compactPill)
                    .help("Clears the untrusted-content flag so memory and routine changes apply immediately again.")
            }
            Text("This conversation read untrusted content, so these changes were not applied.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(bot.pendingReview) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.summary).font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Dismiss") { bot.dismissPending(item) }.buttonStyle(.compactPill)
                    Button("Apply") { bot.approvePending(item) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.warning.opacity(0.4), lineWidth: 1))
    }
}
