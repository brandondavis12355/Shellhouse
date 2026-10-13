import AgentCore
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


/// Live status of a set of bots, one sentence per state — "Mr. Smith and
/// Bugbot are working…", "Cleo is responding…". Bots in the same state share
/// a line; when a line names several bots its color rotates through theirs
/// every couple of seconds, so "more than one" is visible at a glance. Idle
/// bots are hidden, and the whole thing disappears when everyone is idle.
struct BotStatusStrip: View {
    let bots: [Bot]
    private var activity = BotActivity.shared
    private static let colorSwapSeconds: TimeInterval = 2.5

    init(bots: [Bot]) { self.bots = bots }

    private enum State: CaseIterable {
        case responding, working, checking, waiting, approval, idle

        var singular: String {
            switch self {
            case .responding: return "is responding…"
            case .working: return "is working…"
            case .checking: return "is checking the chat…"
            case .waiting: return "is waiting its turn"
            case .approval: return "needs your approval"
            case .idle: return ""
            }
        }

        var plural: String {
            switch self {
            case .responding: return "are responding…"
            case .working: return "are working…"
            case .checking: return "are checking the chat…"
            case .waiting: return "are waiting their turn"
            case .approval: return "need your approval"
            case .idle: return ""
            }
        }
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

    /// One entry per non-empty state, in a stable order, bots in sidebar order.
    private var lines: [(state: State, bots: [Bot])] {
        State.allCases.compactMap { state in
            guard state != .idle else { return nil }
            let members = bots.filter { self.state(of: $0) == state }
            return members.isEmpty ? nil : (state, members)
        }
    }

    var body: some View {
        let current = lines
        if !current.isEmpty {
            // Re-evaluated twice a second so the color swap and any state change show promptly.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(current, id: \.state) { line in
                        row(line.state, line.bots, at: context.date)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .motion(Motion.smooth, value: current.map { "\($0.state)" + $0.bots.map(\.id).joined() })
            }
        }
    }

    @ViewBuilder
    private func row(_ state: State, _ bots: [Bot], at date: Date) -> some View {
        let index = StatusPhrase.colorIndex(at: date.timeIntervalSinceReferenceDate, interval: Self.colorSwapSeconds, count: bots.count)
        let color = Color(hex: bots[index].colorHex)
        let text = StatusPhrase.sentence(names: bots.map(\.name), singular: state.singular, plural: state.plural)
        HStack(spacing: 6) {
            switch state {
            case .responding:
                BouncingDots(colorHex: bots[index].colorHex)
            case .working, .checking:
                ProgressView().controlSize(.mini)
            case .waiting:
                Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(.secondary)
            case .approval:
                Image(systemName: "exclamationmark.shield").font(.system(size: 11)).foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
            Text(text)
                .font(.system(size: 13))
                .italic(state == .responding || state == .working || state == .checking)
                .foregroundStyle(state == .waiting ? Color.secondary : (state == .approval ? Color.orange : color))
                .contentTransition(.opacity)
                .motion(Motion.smooth, value: index)
                .motion(Motion.quick, value: text)
        }
    }
}


/// A 1:1 chat's status line: specific, because there is only one bot to talk
/// about — what it is actually doing right now ("Running run_shell…",
/// "Working… (3/40)", "Waiting for your approval…"), or the animated
/// "is responding…" once its reply starts streaming. (Group chats use the
/// more generic `BotStatusStrip`.)
struct OwnBotStatusView: View {
    let bot: Bot
    private var activity = BotActivity.shared

    init(bot: Bot) { self.bot = bot }

    private var isResponding: Bool {
        activity.spans.contains { $0.botID == bot.id && $0.kind == .running && $0.phase == .responding }
    }

    var body: some View {
        if bot.isProcessingMessage {
            if isResponding {
                RespondingIndicatorView(name: bot.name, colorHex: bot.colorHex, verb: "responding")
            } else {
                HStack(spacing: 6) {
                    if bot.pendingApproval != nil {
                        Image(systemName: "exclamationmark.shield").font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(bot.messageQueue.isEmpty ? bot.status : "\(bot.status) • \(bot.messageQueue.count) queued")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(bot.pendingApproval != nil ? Color.orange : Color(hex: bot.colorHex))
                        .contentTransition(.opacity)
                        .motion(Motion.quick, value: bot.status)
                }
                .transition(.opacity)
            }
        } else {
            Text(bot.messageQueue.isEmpty ? bot.status : "\(bot.status) • \(bot.messageQueue.count) queued")
                .font(.body)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .motion(Motion.quick, value: bot.status)
        }
    }
}
