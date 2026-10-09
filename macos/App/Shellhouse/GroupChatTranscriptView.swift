import SwiftUI
import AppKit

/// A group chat's shared transcript — each bubble colored/labeled by
/// whichever bot actually said it (or "You"), unlike `TranscriptView`
/// (one bot, one color throughout). No streaming-in-place here: a
/// member's reply appears once its isolated turn finishes, not
/// token-by-token — see `GroupChatSession.runWorker`.
struct GroupChatTranscriptView: View {
    let messages: [GroupMessage]
    /// For color lookup only — `speakerBotID` -> hex, so a member's
    /// bubble matches its avatar color elsewhere in the app. A member
    /// removed from the group (or the app) just falls back to gray.
    let memberColors: [String: String]
    /// `speakerBotID` -> avatar style index, for the small avatar beside a
    /// member's bubble.
    var memberStyles: [String: Int] = [:]
    /// Lowercased member name -> hex, for rendering an `@Name` token
    /// inside a message as a colored pill instead of plain text (see
    /// `MentionPillText`). Separate map from `memberColors` (keyed by id)
    /// since matching happens on the name actually typed/said in the
    /// text, not an id.
    let mentionColors: [String: String]

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                GroupMessageBubble(
                                    message: message,
                                    colorHex: message.speakerBotID.flatMap { memberColors[$0] },
                                    avatarStyle: message.speakerBotID.flatMap { memberStyles[$0] },
                                    mentionColors: mentionColors
                                )
                                .id(message.id)
                            }
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: Theme.chatColumnWidth)
                        .frame(maxWidth: .infinity)
                        // See `TranscriptView`'s matching comment — pins
                        // short transcripts to the top of the pane
                        // instead of leaving them centered/bottom-heavy
                        // when there isn't enough history to fill it.
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .topFade()
                .onChange(of: messages.last?.id) { _, _ in
                    if let last = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

private struct GroupMessageBubble: View {
    let message: GroupMessage
    let colorHex: String?
    let avatarStyle: Int?
    let mentionColors: [String: String]

    private var isFriend: Bool { message.externalUserID != nil }
    private var isUser: Bool { message.speakerBotID == nil && !isFriend }
    /// Speaker-name tint: the member's own color; teal for a friend.
    private var nameColor: Color {
        if isFriend { return .teal }
        return Color(hex: colorHex ?? "#8E8E93")
    }
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        if message.isSystem == true {
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 72) }
            if !isUser { speakerAvatar }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser {
                    HStack(spacing: 6) {
                        Text(message.speakerName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(nameColor)
                        if isFriend {
                            Text("friend")
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .background(Color.teal.opacity(0.2), in: Capsule())
                                .foregroundStyle(.teal)
                        }
                    }
                    .padding(.leading, 6)
                }
                MentionPillText(text: message.text, mentionColors: mentionColors, fontSize: 16)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(isUser ? Theme.userBubble : Theme.bubble)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                    .help("\(isUser ? "You" : message.speakerName) · \(Self.timeFormatter.string(from: message.timestamp))")
            }
            if !isUser { Spacer(minLength: 72) }
        }
    }

    @ViewBuilder
    private var speakerAvatar: some View {
        if let colorHex {
            BotAvatar(colorHex: colorHex, style: AvatarStyle(rawValue: avatarStyle ?? 0) ?? .blob, size: 32)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Theme.chip, in: Circle())
        }
    }
}
