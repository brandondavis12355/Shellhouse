import AgentCore
import AppKit
import SwiftUI

/// App-wide "debug mode" switch (Settings > Debug) — a single shared
/// instance rather than per-bot state, since every bot needs to check the
/// same flag, and a plain `class` (not a View) can't use `@AppStorage`
/// directly. Backed by the same `UserDefaults` key either way, so this
/// stays in sync with itself across app launches; there's deliberately
/// only one source of truth (unlike `ContentView`'s `appearanceMode`,
/// this has no other view depending on a `@AppStorage` binding of its
/// own to keep in sync with).
@MainActor
@Observable
final class DebugSettings {
    static let shared = DebugSettings()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "debugModeEnabled") }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "debugModeEnabled")
    }
}

/// One line of the debug console — a raw internal event from some bot's
/// agent loop (status changes, tool calls/results, live model output),
/// captured regardless of which bot's chat is currently open, or whether
/// this is that bot's own chat, a group turn, or a delegation (see
/// `Bot.logToDebugConsole`). `text` is `var`, not `let` — a streaming
/// `.messageDelta` run of entries appends into the last one instead of
/// spawning a fresh row per token (see `DebugLog.logDelta`).
struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let botName: String
    let botColorHex: String
    let kind: Kind
    /// Which run this came from — this bot's own chat (`nil`), a group
    /// turn, a delegation, or a routine, set by `Bot.logToDebugConsole`.
    /// Isolated runs are otherwise indistinguishable from the bot's own
    /// chat in this feed, which matters most for exactly the runs that
    /// are already a black box elsewhere in the UI.
    let context: String?
    var text: String
    var isStreaming = false

    enum Kind: String, Hashable {
        case status, tool, message, error
        /// What the user (or a friend) typed.
        case user
    }
}

/// The live log `DebugConsoleView` renders — a single shared instance,
/// same reasoning as `DebugSettings`: the point is seeing every bot's
/// internal activity in one place, not just whichever bot's chat happens
/// to be open.
@MainActor
@Observable
final class DebugLog {
    static let shared = DebugLog()

    private(set) var entries: [DebugLogEntry] = []
    /// Caps memory/rendering cost for a long-running session — oldest
    /// entries just roll off once a run generates enough of them, the
    /// same trade `AgentRuntime.pruneOldScreenshots` makes for images.
    private static let maxEntries = 2000
    /// Per-entry text cap — a tool result or model message can be
    /// arbitrarily long (a big `read_file`, a long screenshot JSON blob),
    /// and one giant row defeats the point of a scannable feed just as
    /// much as too many small ones would. The full, untruncated text is
    /// still wherever it originally came from (the transcript, the tool
    /// result itself); this is a console, not the only record of it.
    private static let maxEntryLength = 2000

    private init() {}

    private struct PendingDelta { var bot: String; var colorHex: String; var context: String?; var text: String }
    private var pendingDelta: PendingDelta?
    private var deltaFlushTask: Task<Void, Never>?

    private func flushPendingDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard let pending = pendingDelta else { return }
        pendingDelta = nil
        applyDelta(bot: pending.bot, colorHex: pending.colorHex, context: pending.context, delta: pending.text)
    }

    func log(bot: String, colorHex: String, kind: DebugLogEntry.Kind, context: String? = nil, text: String) {
        flushPendingDelta()
        // The finished reply replaces the entry its stream was building, rather than logging the same text twice.
        if kind == .message, let last = entries.last, last.isStreaming, last.botName == bot, last.context == context {
            entries[entries.count - 1] = DebugLogEntry(botName: bot, botColorHex: colorHex, kind: kind, context: context, text: Self.cap(text))
            return
        }
        entries.append(DebugLogEntry(botName: bot, botColorHex: colorHex, kind: kind, context: context, text: Self.cap(text)))
        trim()
    }

    /// `.messageDelta` comes in one small token/chunk at a time — a
    /// fresh row per chunk would make the console unreadable and blow
    /// through `maxEntries` almost instantly. Appends onto the last
    /// entry instead, as long as it's still an in-progress stream from
    /// the SAME bot/context; anything else (a tool call, a status
    /// change, a different bot's delta) starts a new row.
    func logDelta(bot: String, colorHex: String, context: String? = nil, delta: String) {
        // Coalesced (~80ms): appending per token invalidated the whole
        // 2000-row entries array hundreds of times a reply.
        if var pending = pendingDelta, pending.bot == bot, pending.context == context {
            pending.text += delta
            pendingDelta = pending
        } else {
            flushPendingDelta()
            pendingDelta = PendingDelta(bot: bot, colorHex: colorHex, context: context, text: delta)
        }
        if deltaFlushTask == nil {
            deltaFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                self?.flushPendingDelta()
            }
        }
    }

    private func applyDelta(bot: String, colorHex: String, context: String?, delta: String) {
        if let last = entries.last, last.isStreaming, last.botName == bot, last.context == context,
           last.text.count < Self.maxEntryLength {
            entries[entries.count - 1].text += delta
        } else {
            entries.append(DebugLogEntry(botName: bot, botColorHex: colorHex, kind: .message, context: context, text: delta, isStreaming: true))
        }
        trim()
    }

    /// A reply that ended up with no text to show (the runtime blanked a repeat): drop what its stream wrote.
    func discardStreaming(bot: String, context: String?) {
        flushPendingDelta()
        if let last = entries.last, last.isStreaming, last.botName == bot, last.context == context { entries.removeLast() }
    }

    func clear() {
        pendingDelta = nil
        entries.removeAll()
    }

    private static func cap(_ text: String) -> String {
        guard text.count > maxEntryLength else { return text }
        return text.prefix(maxEntryLength) + "… (\(text.count - maxEntryLength) more chars truncated)"
    }

    private func trim() {
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}

/// One-shot dump of the app's effective configuration into the debug
/// console — logged at launch (when debug mode is on) and whenever debug
/// mode is switched on. Secrets are never printed: only whether one is
/// present.
@MainActor
enum StartupConfigLogger {
    static func log(bots: [Bot], groups: [GroupChatSession]) {
        guard DebugSettings.shared.isEnabled else { return }
        Task { @MainActor in
            var lines: [String] = []
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "?"
            let build = info["CFBundleVersion"] as? String ?? "?"
            let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            lines.append("── App ──")
            lines.append("Shellhouse \(version) (\(build)) · \(Bundle.main.bundleIdentifier ?? "?")")
            lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(ProcessInfo.processInfo.processorCount) cores · \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)) RAM")
            lines.append("App Sandbox: \(sandboxed ? "yes" : "no (not detected)")")
            let dataDir = AppData.root.path
            lines.append("Data dir: \(dataDir)")

            lines.append("── Sandbox host ──")
            lines.append("SSH tunnel: \(RemoteHost.user)@\(RemoteHost.host) → manager \(managerBaseURL.absoluteString)")
            let hasToken = ((try? await SecretStore().resolveForExecution(names: [managerTokenName]))?[managerTokenName]) != nil
            lines.append("Manager token in Keychain: \(hasToken ? "present" : "MISSING")")

            lines.append("── Models ──")
            let ollamaURL = URL(string: "http://127.0.0.1:11434")!
            lines.append("Ollama: \(ollamaURL.absoluteString) · num_ctx \(OllamaBackend.contextWindowTokens) · keep_alive -1")
            if let models = try? await OllamaBackend().availableModels() {
                lines.append("Ollama reachable · \(models.count) model(s): \(models.sorted().prefix(8).joined(separator: ", "))\(models.count > 8 ? ", …" : "")")
            } else {
                lines.append("Ollama NOT reachable")
            }

            let serverEnv = await ollamaServerEnvironment()
            if let parallel = serverEnv["OLLAMA_NUM_PARALLEL"] {
                var line = "Ollama parallel: OLLAMA_NUM_PARALLEL=\(parallel)"
                if let loaded = serverEnv["OLLAMA_MAX_LOADED_MODELS"] { line += " · MAX_LOADED_MODELS=\(loaded)" }
                if let ctx = serverEnv["OLLAMA_CONTEXT_LENGTH"] { line += " · server CONTEXT_LENGTH=\(ctx)" }
                lines.append(line + " (read from the running server)")
                if parallel == "1" { lines.append("  → bot replies are served one at a time; raise OLLAMA_NUM_PARALLEL to let bots overlap") }
            } else {
                let defaults = OllamaManager.Config()
                lines.append("Ollama parallel: not readable from inside the app sandbox (check with `ps -Eww -p $(lsof -ti tcp:11434 -sTCP:LISTEN) | tr ' ' '\\n' | grep OLLAMA_`); when this app starts `ollama serve` itself it uses OLLAMA_NUM_PARALLEL=\(defaults.numParallel), MAX_LOADED_MODELS=\(defaults.maxLoadedModels)")
                lines.append("  note: bots send requests at the same time, but a local model still has to process each bot's whole prompt (prefill) — with big prompts and a large model that is what makes replies arrive one after another. See ~/.ollama/logs/server.log: 'cache hit total=… left=…' shows prompt size per request.")
            }

            lines.append("── Bots (\(bots.count)) ──")
            for bot in bots {
                let model = bot.modelProvider == .ollama
                    ? "ollama/\(bot.selectedModel)"
                    : "remote/\(bot.selectedModel) @ \(URL(string: bot.remoteBaseURLText)?.host ?? "?")"
                let shell = bot.blanketShellScopes.isEmpty ? "" : " · ALL-shell grants: \(bot.blanketShellScopes.count)"
                lines.append("• \(bot.name) — \(model) · skills \(bot.selectedSkillIDs.count) · memories \(bot.memories.count) · routines \(bot.routines.count) · max iter \(bot.maxIterationsText) · max tokens \(bot.maxTokensText)\(bot.fallbackProvider != nil && !bot.fallbackModel.isEmpty ? " · fallback \(bot.fallbackProvider == .ollama ? "ollama" : "remote")/\(bot.fallbackModel)" : "")\(shell)")
            }

            lines.append("── Groups (\(groups.count)) ──")
            for group in groups {
                lines.append("• \(group.name) — \(group.members.map(\.name).joined(separator: ", ")) · \(group.displayMessages.count) messages")
            }
            for group in groups {
                if let goal = group.goal {
                    lines.append("Goal [\(group.name)]: “\(goal.title)” · \(goal.status.rawValue) · \(goal.doneCount)/\(goal.steps.count) steps · \(goal.messagesSinceProgress)/\(goal.stallLimit) since progress")
                }
            }
            let friends = FriendsManager.shared
            switch friends.phase {
            case .notConfigured: lines.append("Friends relay: not configured")
            case .connecting: lines.append("Friends relay: connecting…")
            case .connected: lines.append("Friends relay: connected · \(friends.friends.count) friend(s) · \(friends.incoming.count) request(s) waiting")
            case .failed(let message): lines.append("Friends relay: NOT connected — \(message)")
            }
            lines.append("Group chat: async member workers · bot-to-bot cap \(GroupWakePlanner.maxBotMessagesPerUserMessage) per user message · reply gate on")
            lines.append("Shell: run_shell requires approval unless a per-binary or all-shell grant applies")
            lines.append("Debug mode: on")

            DebugLog.shared.log(bot: "App", colorHex: "#8e8e93", kind: .status, context: "startup config", text: lines.joined(separator: "\n"))
        }
    }

    /// `OLLAMA_*` variables of whatever process is listening on Ollama's
    /// port — the settings actually in effect, whether this app started the
    /// server or it was already running. Empty if it can't be read (no
    /// listener, or the sandbox blocks `lsof`/`ps`).
    private static func ollamaServerEnvironment() async -> [String: String] {
        await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "pid=$(lsof -nP -iTCP:11434 -sTCP:LISTEN -t 2>/dev/null | head -1); [ -n \"$pid\" ] && ps -Eww -o command= -p \"$pid\" 2>/dev/null"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            guard (try? task.run()) != nil else { return [:] }
            let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            killer.cancel()
            var result: [String: String] = [:]
            for token in (String(data: data, encoding: .utf8) ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                guard token.hasPrefix("OLLAMA_"), let eq = token.firstIndex(of: "=") else { continue }
                result[String(token[..<eq])] = String(token[token.index(after: eq)...])
            }
            return result
        }.value
    }
}


/// Live record of what every bot is doing right now, so concurrency is
/// visible: which bots are mid-run at the same moment, what each is waiting
/// on, and the peak overlap seen this session. Spans are opened/closed by
/// `Bot` around its runs; cheap enough to record even with debug mode off.
@MainActor
@Observable
final class BotActivity {
    static let shared = BotActivity()

    enum Kind: String {
        /// Waiting for this bot's run lock (it is already doing something else).
        case queued
        /// A full agent run (own chat, group turn, delegation, routine).
        case running
        /// A quick model check (reply gate, goal intake).
        case checking
    }

    /// What a running span is doing right now: `working` = thinking, running
    /// tools, or between steps; `responding` = its reply is streaming out.
    enum Phase { case working, responding }

    struct Span: Identifiable {
        let id = UUID()
        let botID: String
        let botName: String
        let colorHex: String
        let kind: Kind
        let detail: String
        let since = Date()
        var phase: Phase = .working
    }

    private(set) var spans: [Span] = []
    private(set) var peakConcurrent = 0
    private(set) var peakAt: Date?

    private init() {}

    /// Bots with at least one model-active span (running or checking).
    var concurrentBotCount: Int {
        Set(spans.filter { $0.kind != .queued }.map(\.botID)).count
    }

    @discardableResult
    func begin(bot: Bot, kind: Kind, detail: String) -> UUID {
        let span = Span(botID: bot.id, botName: bot.name, colorHex: bot.colorHex, kind: kind, detail: detail)
        spans.append(span)
        let now = concurrentBotCount
        if now > peakConcurrent { peakConcurrent = now; peakAt = Date() }
        return span.id
    }

    func end(_ id: UUID?) {
        guard let id else { return }
        spans.removeAll { $0.id == id }
    }

    /// Flips the bot's current running span between working and responding.
    /// Cheap no-op when nothing changes, so it's safe to call per token.
    func setPhase(botID: String, _ phase: Phase) {
        guard let index = spans.firstIndex(where: { $0.botID == botID && $0.kind == .running }),
              spans[index].phase != phase else { return }
        spans[index].phase = phase
    }

    func resetPeak() {
        peakConcurrent = concurrentBotCount
        peakAt = nil
    }
}

/// One row per bot at the top of the debug console: idle, running (and
/// what), queued behind its own run lock, or waiting for an approval — plus
/// how many bots are active at once and the peak overlap.
struct BotActivityPanel: View {
    let bots: [Bot]
    private var activity = BotActivity.shared

    init(bots: [Bot]) { self.bots = bots }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Bot activity").font(.caption).bold()
                    let active = activity.concurrentBotCount
                    Text("\(active) of \(bots.count) working now")
                        .font(.caption2)
                        .foregroundStyle(active >= 2 ? Color.green : .secondary)
                    Spacer()
                    Text("peak \(activity.peakConcurrent) at once")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(activity.peakAt.map { "Reached at \($0.formatted(date: .omitted, time: .standard))" } ?? "No overlap yet")
                    Button("Reset") { activity.resetPeak() }.font(.caption2).buttonStyle(.link)
                }
                ForEach(bots) { bot in
                    row(for: bot, now: context.date)
                }
            }
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(for bot: Bot, now: Date) -> some View {
        let botSpans = activity.spans.filter { $0.botID == bot.id }
        let modelActive = botSpans.contains { $0.kind != .queued }
        let waitingApproval = bot.pendingApproval != nil
        let dotColor: Color = waitingApproval ? .orange : (modelActive ? .green : (botSpans.isEmpty ? Color.gray.opacity(0.5) : .yellow))
        return HStack(alignment: .top, spacing: 6) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 4)
            Text(bot.name)
                .font(.caption2).bold()
                .foregroundStyle(Color(hex: bot.colorHex))
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                if waitingApproval {
                    Text("waiting for your approval").font(.caption2).foregroundStyle(.orange)
                }
                ForEach(botSpans) { span in
                    let seconds = Int(now.timeIntervalSince(span.since))
                    Text("\(span.kind == .running ? (span.phase == .responding ? "responding" : "working") : span.kind.rawValue): \(span.detail) · \(seconds)s")
                        .font(.caption2)
                        .foregroundStyle(span.kind == .queued ? Color.yellow : .primary)
                        .lineLimit(1)
                }
                if botSpans.isEmpty && !waitingApproval {
                    Text(bot.sandbox == nil ? "sandbox not ready" : "idle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
