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

/// The right-hand pane `ContentView` shows alongside the normal sidebar+
/// detail split when `DebugSettings.shared.isEnabled` is on — every
/// bot's raw agent-loop activity in one scrolling feed: status changes,
/// tool calls and their results, and the model's live token stream,
/// including from group turns and delegations, which are otherwise a
/// black box in the normal chat UI (see `group-chat-turns.md`).
struct DebugConsoleView: View {
    private var log = DebugLog.shared
    /// `nil` means "every bot" — narrowing to one is the main lever for
    /// keeping this readable once several bots are active at once, since
    /// this feed is intentionally app-wide, not per-chat.
    @State private var botFilter: String?
    @State private var kindFilter: DebugLogEntry.Kind?

    private var botNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in log.entries where !seen.contains(entry.botName) {
            seen.insert(entry.botName)
            ordered.append(entry.botName)
        }
        return ordered
    }

    private var filteredEntries: [DebugLogEntry] {
        log.entries.filter { entry in
            (botFilter == nil || entry.botName == botFilter) && (kindFilter == nil || entry.kind == kindFilter)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    /// Plain-text dump of `entries` — what "Copy" puts on the pasteboard
    /// and "Export…" saves to disk. Each row's own `.textSelection` only
    /// ever covers that one row's body text (a per-row `Text`, same
    /// underlying limitation `MentionPillText` had for a single
    /// message — see its doc comment), so drag-selecting or Cmd+A never
    /// grabbed more than whatever row you started in. This is the actual
    /// way to get the whole (filtered) log out, not a native selection.
    private func formattedText(for entries: [DebugLogEntry]) -> String {
        entries.map { entry in
            let context = entry.context.map { " (\($0))" } ?? ""
            let header = "\(Self.timeFormatter.string(from: entry.timestamp))  \(entry.botName)\(context)  [\(entry.kind.rawValue)]"
            return "\(header)\n\(entry.text)"
        }.joined(separator: "\n\n")
    }

    private func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(formattedText(for: filteredEntries), forType: .string)
    }

    private func exportAll() {
        let text = formattedText(for: filteredEntries)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "debug-console-\(Int(Date().timeIntervalSince1970)).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debug Console").font(.headline)
                Spacer()
                Text("\(filteredEntries.count)").font(.caption).foregroundStyle(.secondary)
                Button("Copy") { copyAll() }
                    .font(.caption)
                    .disabled(filteredEntries.isEmpty)
                    .help("Copy everything currently shown (respects the filters below) to the clipboard.")
                Button("Export…") { exportAll() }
                    .font(.caption)
                    .disabled(filteredEntries.isEmpty)
                    .help("Save everything currently shown (respects the filters below) to a text file.")
                Button("Clear") { log.clear() }
                    .font(.caption)
                    .disabled(log.entries.isEmpty)
            }
            .padding(10)

            HStack(spacing: 8) {
                Picker("Bot", selection: $botFilter) {
                    Text("All bots").tag(String?.none)
                    ForEach(botNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                Picker("Kind", selection: $kindFilter) {
                    Text("All kinds").tag(DebugLogEntry.Kind?.none)
                    ForEach([DebugLogEntry.Kind.status, .tool, .message, .error], id: \.self) { kind in
                        Text(kind.rawValue.capitalized).tag(DebugLogEntry.Kind?.some(kind))
                    }
                }
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()
            if filteredEntries.isEmpty {
                VStack {
                    Spacer()
                    Text(log.entries.isEmpty
                        ? "Nothing yet — this fills in as any bot does something."
                        : "No entries match the current filter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Spacer()
                }
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(filteredEntries) { entry in
                                        DebugLogRow(entry: entry).id(entry.id)
                                    }
                                }
                                .padding(8)
                                // See `TranscriptView`'s matching comment
                                // — keeps a short log pinned to the top
                                // instead of bottom-anchored with empty
                                // space above it.
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: geometry.size.height, alignment: .top)
                        }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: filteredEntries.last?.id) { _, _ in
                            if let last = filteredEntries.last?.id {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DebugLogRow: View {
    let entry: DebugLogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var kindLabel: String {
        switch entry.kind {
        case .status: return "status"
        case .tool: return "tool"
        case .message: return "model"
        case .error: return "error"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(Color(hex: entry.botColorHex)).frame(width: 6, height: 6)
                Text(entry.botName).font(.caption2).bold().foregroundStyle(Color(hex: entry.botColorHex))
                if let context = entry.context {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
                Text(kindLabel).font(.caption2).foregroundStyle(.secondary)
                Text(Self.timeFormatter.string(from: entry.timestamp)).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            Text(entry.text.isEmpty ? "…" : entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.kind == .error ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // On the whole row, not just the body text — covers the header
        // line (bot/context/kind/time) too, for a quick single-row copy.
        // Bulk copying across many rows at once is what the header's
        // "Copy"/"Export…" buttons are for (see `DebugConsoleView`).
        .textSelection(.enabled)
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
            let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AICompute").path
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
                lines.append("Ollama parallel: couldn't read the running server's environment; when this app starts `ollama serve` itself it uses OLLAMA_NUM_PARALLEL=\(defaults.numParallel), MAX_LOADED_MODELS=\(defaults.maxLoadedModels)")
            }

            lines.append("── Bots (\(bots.count)) ──")
            for bot in bots {
                let model = bot.modelProvider == .ollama
                    ? "ollama/\(bot.selectedModel)"
                    : "remote/\(bot.selectedModel) @ \(URL(string: bot.remoteBaseURLText)?.host ?? "?")"
                let shell = bot.blanketShellScopes.isEmpty ? "" : " · ALL-shell grants: \(bot.blanketShellScopes.count)"
                lines.append("• \(bot.name) — \(model) · skills \(bot.selectedSkillIDs.count) · memories \(bot.memories.count) · routines \(bot.routines.count) · max iter \(bot.maxIterationsText) · max tokens \(bot.maxTokensText)\(shell)")
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
