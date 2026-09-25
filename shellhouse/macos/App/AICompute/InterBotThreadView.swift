import SwiftUI

/// The user's read-only window into one bot-to-bot exchange — opened by
/// tapping a "Messaged <name>…" notice in `TranscriptView`. There's no
/// input here on purpose: the two bots are the only participants: see
/// `Bot.delegateToBot`/`InterBotStore`.
struct InterBotThreadView: View {
    let myBotID: String
    let myBotName: String
    let myBotColorHex: String
    let peerID: String
    let peerName: String
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [InterBotMessage] = []
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(myBotName) ↔ \(peerName)").font(.headline)
                Spacer()
                Text("Read-only").font(.caption).foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        threadBubble(message)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 480)
        .task { messages = InterBotStore.load(myBotID, peerID) }
    }

    private func threadBubble(_ message: InterBotMessage) -> some View {
        let isMine = message.fromBotID == myBotID
        return HStack(spacing: 0) {
            if isMine { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.fromBotName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(isMine ? Color(hex: myBotColorHex) : .secondary)
                    Text(Self.timeFormatter.string(from: message.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((isMine ? Color(hex: myBotColorHex) : Color.secondary).opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !isMine { Spacer(minLength: 32) }
        }
    }
}
