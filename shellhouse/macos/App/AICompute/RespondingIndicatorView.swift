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
    var verb = "responding"

    var body: some View {
        HStack(spacing: 6) {
            BouncingDots(colorHex: colorHex)
            Text("\(name) is \(verb)…")
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


/// Every bot's live status in one wrapped block at the bottom of a chat —
/// "is working…" (thinking / running tools) and "is responding…" (its reply
/// is streaming) are distinct, alongside "checking", "waiting" (queued
/// behind its own other run), "needs approval", and idle.
struct BotStatusStrip: View {
    let bots: [Bot]
    private var activity = BotActivity.shared

    init(bots: [Bot]) { self.bots = bots }

    private enum State {
        case responding, working, checking, waiting, approval, idle
    }

    private func state(of bot: Bot) -> State {
        if bot.pendingApproval != nil { return .approval }
        let spans = activity.spans.filter { $0.botID == bot.id }
        if let running = spans.first(where: { $0.kind == .running }) {
            return running.phase == .responding ? .responding : .working
        }
        if spans.contains(where: { $0.kind == .checking }) { return .checking }
        if spans.contains(where: { $0.kind == .queued }) { return .waiting }
        return .idle
    }

    /// Idle bots are hidden — the strip only shows bots doing (or waiting
    /// on) something, and disappears entirely when everyone is idle.
    private var activeBots: [Bot] {
        bots.filter { state(of: $0) != .idle }
    }

    var body: some View {
        if !activeBots.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(activeBots) { bot in
                    chip(for: bot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func chip(for bot: Bot) -> some View {
        let color = Color(hex: bot.colorHex)
        switch state(of: bot) {
        case .responding:
            RespondingIndicatorView(name: bot.name, colorHex: bot.colorHex, verb: "responding")
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("\(bot.name) is working…").font(.system(size: 13)).italic().foregroundStyle(color)
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("\(bot.name) is checking the chat…").font(.system(size: 13)).italic().foregroundStyle(color.opacity(0.8))
            }
        case .waiting:
            HStack(spacing: 6) {
                Image(systemName: "hourglass").font(.system(size: 11))
                Text("\(bot.name) is waiting its turn").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        case .approval:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield").font(.system(size: 11)).foregroundStyle(.orange)
                Text("\(bot.name) needs approval").font(.system(size: 13)).foregroundStyle(.orange)
            }
        case .idle:
            EmptyView()
        }
    }
}
