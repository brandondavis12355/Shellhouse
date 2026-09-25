import SwiftUI

/// A small animated "<Name> is responding…" line — shown in place of the
/// plain status text while a bot is actively generating (1:1 chat, via
/// `Bot.isProcessingMessage`) or mid-turn (group chat, via
/// `GroupChatSession.currentSpeakerName`), so it's clear who's doing what
/// without opening the transcript. `TimelineView(.animation)` drives the
/// dot bounce continuously at the display's own refresh rate — no `Timer`
/// or `@State` bookkeeping to start/stop as this view appears/disappears.
struct RespondingIndicatorView: View {
    let name: String
    let colorHex: String

    var body: some View {
        HStack(spacing: 6) {
            BouncingDots(colorHex: colorHex)
            Text("\(name) is responding…")
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(Color(hex: colorHex))
        }
        .transition(.opacity)
    }
}

private struct BouncingDots: View {
    let colorHex: String
    private let dotCount = 3
    private let cycle: TimeInterval = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<dotCount, id: \.self) { i in
                    let offsetPhase = (t - Double(i) * (cycle / Double(dotCount))).truncatingRemainder(dividingBy: cycle) / cycle
                    let bounce = sin(offsetPhase * .pi).magnitude
                    Circle()
                        .fill(Color(hex: colorHex))
                        .frame(width: 5, height: 5)
                        .offset(y: -bounce * 3)
                        .opacity(0.4 + bounce * 0.6)
                }
            }
        }
    }
}
