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
        SheetScaffold(title: "\(myBotName) ↔ \(peerName)", subtitle: "Read-only") {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(messages) { message in
                    threadBubble(message)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 520, height: 520)
        .task { messages = InterBotStore.load(myBotID, peerID) }
    }

    private func threadBubble(_ message: InterBotMessage) -> some View {
        let isMine = message.fromBotID == myBotID
        return HStack(spacing: 0) {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Text(message.fromBotName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMine ? Color(hex: myBotColorHex) : .secondary)
                    .padding(.horizontal, 6)
                Text(message.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(isMine ? Theme.userBubble : Theme.bubble)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .help(Self.timeFormatter.string(from: message.timestamp))
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }
}
