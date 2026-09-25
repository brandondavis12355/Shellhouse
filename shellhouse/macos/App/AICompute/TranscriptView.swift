import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgentCore

/// The chat transcript — a scrolling column of rounded, role-colored
/// bubbles (right-aligned for you, left-aligned for the bot/tool), matching
/// the reference chat app's look rather than a flat log of labeled text
/// blocks.
///
/// An earlier version of this file was one continuous `NSTextView` so a
/// click-drag could select clean across message boundaries the way Mail or
/// Notes does. Real rounded bubbles need each message's background to be a
/// `RoundedRectangle` sized to its own text, which a single shared text
/// storage can't give per-paragraph — so this trades that continuous
/// selection for one text selection per bubble (`.textSelection(.enabled)`
/// per message) in exchange for the actual look being asked for.
struct TranscriptView: View {
    let messages: [DisplayMessage]
    /// This bot's own name/color — its bubbles pick up the same color as
    /// its avatar everywhere else in the app instead of a flat system gray.
    var botName: String = "Assistant"
    var botColorHex: String = "#8E8E93"
    /// This bot's own id — the other half of the pair key `MessageBubble`
    /// needs to look up an inter-bot thread (`InterBotStore.load`) when a
    /// "Messaged <name>…" notice is tapped.
    var botID: String = ""
    /// Lowercased OTHER-bot name -> colorHex, for rendering an `@Name`
    /// token as a colored pill (see `MentionPillText`) — who this bot
    /// could delegate to via `message_bot`, same idea as the group chat's
    /// own member pills.
    var mentionColors: [String: String] = [:]
    /// Called with (peerID, peerName) when a "Messaged <name>…" notice is
    /// tapped. Owned by `BotDetailView`, NOT a `@State` local to the
    /// tapped bubble — a bubble's identity is tied to its message, and a
    /// new message arriving elsewhere in this same transcript shouldn't
    /// be able to reset (and thereby dismiss the sheet for) a completely
    /// unrelated bubble's local state.
    var onOpenInterBotThread: (String, String) -> Void = { _, _ in }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { message in
                                if message.role != .system {
                                    MessageBubble(
                                        message: message, botName: botName, botColorHex: botColorHex, botID: botID,
                                        mentionColors: mentionColors, onOpenInterBotThread: onOpenInterBotThread
                                    )
                                    .id(message.id)
                                }
                            }
                        }
                        .padding(8)
                        // Absorbs whatever's left over when there aren't
                        // enough messages to fill the viewport — without
                        // it, `.frame(minHeight:)` below would still
                        // stretch this VStack to the full pane height,
                        // but `alignment: .top` on that frame is what
                        // actually pins the messages to the top of that
                        // extra space instead of centering them in it.
                        Spacer(minLength: 0)
                    }
                    // Tied to the pane's own live size (via `GeometryReader`),
                    // not a fixed constant — so this keeps working whether
                    // the window is maximized, split, or resized. Only
                    // matters when there's little enough history that it
                    // doesn't already fill the pane; once it does, this
                    // has no effect and normal scrolling takes over.
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                // `defaultScrollAnchor(.bottom)` handles the *initial* layout —
                // opening a chat with history lands on the newest message
                // immediately, not the oldest. `scrollTo` alone in `.onAppear`
                // isn't reliable here: `LazyVStack` hasn't necessarily
                // instantiated the last row's view yet at that point, so the
                // scroll-to-target can silently miss on first open.
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, _ in
                    if let last = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

/// One chat bubble. Role decides color, alignment, and font — the bot's own
/// color for its messages (tying the chat to the same identity as its
/// avatar and sidebar tagline), a fixed blue for yours, orange/monospaced
/// for raw tool output.
private struct MessageBubble: View {
    let message: DisplayMessage
    let botName: String
    let botColorHex: String
    let botID: String
    let mentionColors: [String: String]
    let onOpenInterBotThread: (String, String) -> Void
    /// Collapsed by default for both `toolResultRow` and
    /// `taskSummaryRow` — a plain per-row toggle, not persisted, so it
    /// resets to collapsed if the row is scrolled far enough off-screen
    /// to be recreated. Acceptable here (unlike the inter-bot-thread
    /// sheet this used to also gate): staying collapsed on rebuild is the
    /// same default state anyway, not a surprising loss.
    @State private var isExpanded = false

    private static let bodyFontSize = NSFont.systemFontSize + 4
    private static let toolFontSize = NSFont.smallSystemFontSize + 4
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var roleStyle: (label: String, color: Color, isUser: Bool, font: Font) {
        switch message.role {
        case .user:
            return ("You", .blue, true, .system(size: Self.bodyFontSize))
        case .assistant:
            return (botName, Color(hex: botColorHex), false, .system(size: Self.bodyFontSize))
        case .tool:
            return ("Tool", .orange, false, .system(size: Self.toolFontSize, design: .monospaced))
        case .system:
            return ("", .clear, false, .system(size: Self.bodyFontSize))
        }
    }

    var body: some View {
        if let peerID = message.interBotPeerID, let peerName = message.interBotPeerName {
            interBotNotice(peerID: peerID, peerName: peerName)
        } else if message.role == .tool {
            toolResultRow
        } else if message.isTaskSummary {
            taskSummaryRow
        } else {
            let style = roleStyle
            HStack(spacing: 0) {
                if style.isUser { Spacer(minLength: 48) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(style.label)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(style.color)
                        Text(Self.timeFormatter.string(from: message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !message.text.isEmpty {
                        // Mention pills take over the whole message's
                        // rendering (word-level, no markdown highlighting)
                        // only when there's actually an @-mention of a
                        // known bot in it — the common case with no
                        // mention keeps the richer code/bold/link
                        // highlighting below.
                        if MentionPillText.containsKnownMention(message.text, mentionColors: mentionColors) {
                            MentionPillText(text: message.text, mentionColors: mentionColors, fontSize: style.font == .system(size: Self.toolFontSize, design: .monospaced) ? Self.toolFontSize : Self.bodyFontSize)
                                .textSelection(.enabled)
                        } else {
                            Text(highlightedText)
                                .font(style.font)
                                .textSelection(.enabled)
                        }
                    }
                    if !message.attachmentNames.isEmpty {
                        ForEach(message.attachmentNames, id: \.self) { filename in
                            AttachmentChip(filename: filename, isImage: isImageFilename(filename))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(style.color.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if !style.isUser { Spacer(minLength: 48) }
            }
        }
    }

    /// "Messaged <name>…" — tapping it reveals the read-only exchange
    /// (`InterBotThreadView`) between this bot and the one it delegated
    /// to. Not a normal chat bubble on purpose: this is the ONE thing the
    /// user sees in-line about a delegation unless they go looking.
    private func interBotNotice(peerID: String, peerName: String) -> some View {
        Button {
            onOpenInterBotThread(peerID, peerName)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.up.right")
                    .font(.caption)
                Text("Messaged \(peerName)…")
                    .font(.caption)
                    .italic()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Read-only — tap to see this bot's exchange with \(peerName).")
    }

    /// A raw tool result — collapsed by default to "Ran <name>…" instead
    /// of the full JSON inline. The full content is already in
    /// `displayMessages`/persisted transcript regardless of whether this
    /// is ever expanded; this only controls what's shown, not what's kept.
    private var toolResultRow: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(message.text)
                .font(.system(size: Self.toolFontSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption)
                Text("Ran \(message.toolName ?? "a tool")…")
                    .font(.caption)
                    .italic()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 420, alignment: .leading)
    }

    /// The `finish_task` summary — usually a near-duplicate recap of
    /// whatever the model already said in the reply just before it (see
    /// `AgentRuntime.loop`'s finish_task branch), so this stays collapsed
    /// by default rather than showing the same result twice in a row.
    private var taskSummaryRow: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(message.text)
                .font(.system(size: Self.bodyFontSize))
                .textSelection(.enabled)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                Text("Done — tap for summary")
                    .font(.caption)
                    .italic()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 420, alignment: .leading)
    }

    /// Bridges `TranscriptHighlighter`'s `NSAttributedString` (code/bold/
    /// links/paths/status-word coloring — unchanged from before) into
    /// something `Text` can render. Falls back to the plain string on a
    /// bridging failure rather than showing nothing.
    private var highlightedText: AttributedString {
        let ns = TranscriptHighlighter.highlight(message.text, baseFont: .systemFont(ofSize: roleStyle.font == .system(size: Self.toolFontSize, design: .monospaced) ? Self.toolFontSize : Self.bodyFontSize))
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(message.text)
    }

    private func isImageFilename(_ filename: String) -> Bool {
        UTType(filenameExtension: (filename as NSString).pathExtension)?.conforms(to: .image) ?? false
    }
}

/// Picks out the parts of a message worth visually distinguishing from
/// plain prose — fenced/inline code, **bold**, links, filesystem paths, and
/// a small set of status words — instead of rendering every message as one
/// flat run of text regardless of what's actually in it.
///
/// A single tokenizing regex pass (rather than several sequential
/// find-and-restyle passes) avoids the index bookkeeping that stripping
/// markdown delimiters (` `` `, `**`) would otherwise require: each pass
/// would shift every range found by a later pass. Walking the source string
/// once, left to right, and appending each gap or match as it's found sidesteps
/// that entirely.
enum TranscriptHighlighter {
    private static let pattern: NSRegularExpression = {
        let codeBlock = #"(?<CODEBLOCK>```(?:[^\n`]*\n)?[\s\S]*?```)"#
        let inlineCode = #"(?<INLINECODE>`[^`\n]+`)"#
        let bold = #"(?<BOLD>\*\*[^*\n]+\*\*)"#
        let exitCode = #"(?<EXITCODE>"exit_code"\s*:\s*-?\d+)"#
        let url = #"(?<URL>https?://\S+)"#
        let path = #"(?<PATH>~?/[\w.\-]+(?:/[\w.\-]+)+)"#
        let keyword = #"(?<KEYWORD>\b(?:ERROR|FAILED|DENIED|WARNING|SUCCESS|APPROVED|COMPLETED|TIMEOUT)\b)"#
        // swiftlint:disable:next force_try — the pattern is a fixed literal; a failure here is a coding error, not runtime data.
        return try! NSRegularExpression(pattern: [codeBlock, inlineCode, bold, exitCode, url, path, keyword].joined(separator: "|"))
    }()

    /// No `.backgroundColor`/paragraph style here anymore — each message is
    /// its own `MessageBubble`, which supplies the rounded, role-colored
    /// background itself. This only ever colors/weights the text.
    static func highlight(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        let nsText = text as NSString
        let result = NSMutableAttributedString()
        var cursor = 0

        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                result.append(NSAttributedString(
                    string: nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    attributes: base
                ))
            }

            if let range = groupRange(match, "CODEBLOCK", in: nsText) {
                result.append(codeBlock(nsText.substring(with: range), baseFont: mono))
            } else if let range = groupRange(match, "INLINECODE", in: nsText) {
                let raw = nsText.substring(with: range)
                result.append(NSAttributedString(
                    string: String(raw.dropFirst().dropLast()),
                    attributes: base.merging([
                        .font: mono,
                        .backgroundColor: NSColor.textColor.withAlphaComponent(0.12),
                    ]) { _, new in new }
                ))
            } else if let range = groupRange(match, "BOLD", in: nsText) {
                let raw = nsText.substring(with: range)
                result.append(NSAttributedString(
                    string: String(raw.dropFirst(2).dropLast(2)),
                    attributes: base.merging([.font: NSFont.boldSystemFont(ofSize: baseFont.pointSize)]) { _, new in new }
                ))
            } else if let range = groupRange(match, "EXITCODE", in: nsText) {
                let raw = nsText.substring(with: range)
                let isZero = raw.hasSuffix(" 0") || raw.hasSuffix(":0")
                result.append(NSAttributedString(
                    string: raw,
                    attributes: base.merging([
                        .font: mono,
                        .foregroundColor: isZero ? NSColor.systemGreen : NSColor.systemRed,
                    ]) { _, new in new }
                ))
            } else if let range = groupRange(match, "URL", in: nsText) {
                let raw = nsText.substring(with: range)
                result.append(NSAttributedString(
                    string: raw,
                    attributes: base.merging([
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: raw,
                    ]) { _, new in new }
                ))
            } else if let range = groupRange(match, "PATH", in: nsText) {
                result.append(NSAttributedString(
                    string: nsText.substring(with: range),
                    attributes: base.merging([.font: mono, .foregroundColor: NSColor.systemTeal]) { _, new in new }
                ))
            } else if let range = groupRange(match, "KEYWORD", in: nsText) {
                let raw = nsText.substring(with: range)
                let color: NSColor = ["SUCCESS", "APPROVED", "COMPLETED"].contains(raw)
                    ? .systemGreen
                    : (raw == "WARNING" ? .systemYellow : .systemRed)
                result.append(NSAttributedString(
                    string: raw,
                    attributes: base.merging([.font: NSFont.boldSystemFont(ofSize: baseFont.pointSize), .foregroundColor: color]) { _, new in new }
                ))
            }

            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            result.append(NSAttributedString(
                string: nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)),
                attributes: base
            ))
        }
        return result
    }

    private static func groupRange(_ match: NSTextCheckingResult, _ name: String, in text: NSString) -> NSRange? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return range
    }

    /// Fenced code renders as its own boxed paragraph: backticks (and an
    /// optional language tag) stripped, monospaced, with a background block
    /// distinct from the bubble's own background so it reads as "quoted
    /// content" rather than more of the surrounding prose.
    private static func codeBlock(_ raw: String, baseFont: NSFont) -> NSAttributedString {
        var body = raw
        if body.hasPrefix("```") { body.removeFirst(3) }
        if body.hasSuffix("```") { body.removeLast(3) }
        if let firstNewline = body.firstIndex(of: "\n"),
           !body[body.startIndex..<firstNewline].contains(where: { $0.isWhitespace }) {
            body.removeSubrange(body.startIndex...firstNewline)
        }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 6
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        return NSAttributedString(
            string: "\n" + body.trimmingCharacters(in: .newlines) + "\n",
            attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.textColor.withAlphaComponent(0.1),
                .paragraphStyle: style,
            ]
        )
    }
}
