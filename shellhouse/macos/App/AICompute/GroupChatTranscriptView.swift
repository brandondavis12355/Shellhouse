import SwiftUI
import AppKit

/// A group chat's shared transcript — each bubble colored/labeled by
/// whichever bot actually said it (or "You"), unlike `TranscriptView`
/// (one bot, one color throughout). No streaming-in-place here: a
/// member's reply appears once its isolated turn finishes, not
/// token-by-token — see `GroupChatSession.runTurn`.
struct GroupChatTranscriptView: View {
    let messages: [GroupMessage]
    /// For color lookup only — `speakerBotID` -> hex, so a member's
    /// bubble matches its avatar color elsewhere in the app. A member
    /// removed from the group (or the app) just falls back to gray.
    let memberColors: [String: String]
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
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { message in
                                GroupMessageBubble(
                                    message: message,
                                    colorHex: message.speakerBotID.flatMap { memberColors[$0] },
                                    mentionColors: mentionColors
                                )
                                .id(message.id)
                            }
                        }
                        .padding(8)
                        // See `TranscriptView`'s matching comment — pins
                        // short transcripts to the top of the pane
                        // instead of leaving them centered/bottom-heavy
                        // when there isn't enough history to fill it.
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
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

private struct GroupMessageBubble: View {
    let message: GroupMessage
    let colorHex: String?
    let mentionColors: [String: String]

    private var isUser: Bool { message.speakerBotID == nil }
    private var color: Color { isUser ? .blue : Color(hex: colorHex ?? "#8E8E93") }
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.speakerName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                    Text(Self.timeFormatter.string(from: message.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                MentionPillText(text: message.text, mentionColors: mentionColors)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !isUser { Spacer(minLength: 48) }
        }
    }
}
