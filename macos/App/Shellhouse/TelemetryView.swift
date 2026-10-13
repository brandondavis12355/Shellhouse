import SwiftUI
import AgentCore
import AgentUI

/// Window › Telemetry: a live report of what the app is doing since it started — model calls and tokens
/// (by bot, purpose and model), tools, approvals, run outcomes, context use and what Ollama has loaded.
/// Refreshes every second. In memory only; Export saves a Markdown copy.
struct TelemetryView: View {
    @State private var loaded: [OllamaBackend.LoadedModel] = []
    @State private var ollamaError: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let snapshot = Telemetry.recorder.snapshot()
            let bots = BotDirectory.main?.allBots() ?? []
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(snapshot, now: timeline.date, bots: bots)
                    totals(snapshot)
                    ollama
                    botsTable(snapshot, bots: bots, now: timeline.date)
                    HStack(alignment: .top, spacing: 16) {
                        breakdown("By purpose", snapshot.byPurpose)
                        breakdown("By model", snapshot.byModel)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        toolsTable(snapshot)
                        outcomes(snapshot)
                    }
                    feed(snapshot)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(Theme.bg)
        .task {
            while !Task.isCancelled {
                do { loaded = try await OllamaBackend().loadedModels(); ollamaError = nil } catch { ollamaError = error.localizedDescription }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: sections

    private func header(_ s: TelemetryRecorder.Snapshot, now: Date, bots: [Bot]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Telemetry").font(.system(size: 22, weight: .bold))
                Text("Live since \(s.startedAt.formatted(date: .omitted, time: .shortened)) · \(Self.duration(now.timeIntervalSince(s.startedAt))) · "
                     + "\(bots.filter(\.isBusy).count) of \(bots.count) bots working")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export…") { saveTranscript(Self.report(s, bots: bots, loaded: loaded), suggestedName: "shellhouse-telemetry-\(Self.fileStamp()).md") }
        }
    }

    private func totals(_ s: TelemetryRecorder.Snapshot) -> some View {
        let t = s.total
        let toolRuns = s.tools.values.reduce(0) { $0 + $1.runs }
        let toolFailures = s.tools.values.reduce(0) { $0 + $1.failures }
        let runs = s.byBot.values.reduce(0) { $0 + $1.runs }
        let stopped = s.byBot.values.reduce(0) { $0 + $1.runsStopped }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            tile("Model calls", "\(t.calls)", t.failedCalls > 0 ? "\(t.failedCalls) failed" : "none failed")
            tile("Tokens in", Self.count(t.promptTokens), "prompt tokens processed")
            tile("Tokens out", Self.count(t.completionTokens), t.tokensPerSecond.map { String(format: "%.0f tok/s generating", $0) } ?? "—")
            tile("Model time", Self.duration(t.seconds), t.loadSeconds > 1 ? "\(Self.duration(t.loadSeconds)) loading models" : "models stayed loaded")
            tile("Tool runs", "\(toolRuns)", "\(toolFailures) failed")
            tile("Runs", "\(runs)", "\(stopped) stopped early")
            tile("Approvals by you", "\((s.approvals["approved"] ?? 0) + (s.approvals["denied_by_user"] ?? 0))",
                 "\(s.approvals["reviewer_auto"] ?? 0) settled by the reviewer")
            tile("Compactions", "\(s.byBot.values.reduce(0) { $0 + $1.compactions })", "context window \(OllamaBackend.contextWindowTokens / 1024)k")
        }
    }

    private var ollama: some View {
        section("Ollama now") {
            if let ollamaError {
                Text("Not reachable: \(ollamaError)").font(.system(size: 13)).foregroundStyle(Theme.warning)
            } else if loaded.isEmpty {
                Text("No models loaded.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { th("Model"); th("Memory"); th("On GPU"); th("Context"); th("Unloads") }
                    ForEach(loaded) { model in
                        GridRow {
                            td(model.name)
                            td(Self.bytes(model.sizeBytes))
                            td(model.sizeBytes > 0 ? "\(Int(Double(model.gpuBytes) / Double(model.sizeBytes) * 100))%" : "—")
                            td(model.contextLength.map { "\($0 / 1024)k" } ?? "—")
                            td(model.expiresAt.map { $0.timeIntervalSinceNow > 86_400 * 365 ? "never" : $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                        }
                    }
                }
            }
        }
    }

    private func botsTable(_ s: TelemetryRecorder.Snapshot, bots: [Bot], now: Date) -> some View {
        section("Bots") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { th("Bot"); th("State"); th("Model"); th("Calls"); th("Tokens in / out"); th("Context"); th("Tools (failed)"); th("Runs (stopped)"); th("Last active") }
                ForEach(bots, id: \.id) { bot in
                    let stats = s.byBot[bot.name] ?? TelemetryRecorder.BotStats()
                    let fill = stats.lastPromptTokens > 0 ? Double(stats.lastPromptTokens) / Double(OllamaBackend.contextWindowTokens) : nil
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: bot.colorHex)).frame(width: 8, height: 8)
                            Text(bot.name).font(.system(size: 13, weight: .medium))
                        }
                        td(Self.state(of: bot), color: bot.pendingApproval != nil || bot.pendingCredentialRequest != nil ? Theme.warning : nil)
                        td(bot.selectedModel)
                        td("\(stats.model.calls)")
                        td("\(Self.count(stats.model.promptTokens)) / \(Self.count(stats.model.completionTokens))")
                        td(fill.map { "\(Int($0 * 100))%" } ?? "—", color: (fill ?? 0) > 0.85 ? Theme.warning : nil)
                        td("\(stats.toolRuns) (\(stats.toolFailures))")
                        td("\(stats.runs) (\(stats.runsStopped))")
                        td(stats.lastActivity.map { Self.ago(now.timeIntervalSince($0)) } ?? "—")
                    }
                }
            }
        }
    }

    private func breakdown(_ title: String, _ rows: [String: TelemetryRecorder.Totals]) -> some View {
        section(title) {
            if rows.isEmpty { Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if !rows.isEmpty { GridRow { th(""); th("Calls"); th("In / out"); th("Time"); th("Speed") } }
                ForEach(rows.sorted { $0.value.calls > $1.value.calls }, id: \.key) { key, t in
                    GridRow {
                        td(key)
                        td("\(t.calls)")
                        td("\(Self.count(t.promptTokens)) / \(Self.count(t.completionTokens))")
                        td(Self.duration(t.seconds))
                        td(t.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "—")
                    }
                }
            }
        }
    }

    private func toolsTable(_ s: TelemetryRecorder.Snapshot) -> some View {
        section("Tools") {
            if s.tools.isEmpty { Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if !s.tools.isEmpty { GridRow { th("Tool"); th("Runs"); th("Failed"); th("Avg time") } }
                ForEach(s.tools.sorted { $0.value.runs > $1.value.runs }.prefix(15), id: \.key) { name, t in
                    GridRow {
                        td(name)
                        td("\(t.runs)")
                        td("\(t.failures)", color: t.runs > 0 && Double(t.failures) / Double(t.runs) > 0.3 ? Theme.warning : nil)
                        td(String(format: "%.1f s", t.seconds / Double(max(1, t.runs))))
                    }
                }
            }
        }
    }

    private func outcomes(_ s: TelemetryRecorder.Snapshot) -> some View {
        section("Approvals and stops") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(s.approvals.sorted { $0.value > $1.value }, id: \.key) { outcome, n in
                    HStack { td(Self.outcomeLabel(outcome)); Spacer(); td("\(n)") }
                }
                if !s.stopReasons.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Why runs stopped early").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(s.stopReasons.sorted { $0.value > $1.value }, id: \.key) { reason, n in
                        HStack(alignment: .top) { td(reason); Spacer(); td("\(n)") }
                    }
                }
            }
        }
    }

    private func feed(_ s: TelemetryRecorder.Snapshot) -> some View {
        section("Activity") {
            VStack(alignment: .leading, spacing: 3) {
                if s.recent.isEmpty { Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(.secondary) }
                ForEach(s.recent.suffix(60).reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.time.formatted(date: .omitted, time: .standard)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        Text(event.bot).font(.system(size: 12, weight: .medium)).frame(width: 90, alignment: .leading).lineLimit(1)
                        Text(event.kind).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(event.kind.contains("fail") || event.kind.contains("error") || event.kind.contains("stopped") ? Theme.warning : .secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(event.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func th(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func td(_ text: String, color: Color? = nil) -> some View {
        Text(text).font(.system(size: 12)).monospacedDigit().foregroundStyle(color ?? .primary).lineLimit(1)
    }

    // MARK: formatting

    static func state(of bot: Bot) -> String {
        if bot.pendingCredentialRequest != nil { return "waiting for credentials" }
        if bot.pendingApproval != nil { return "waiting for approval" }
        if bot.isBusy { return "working" }
        switch bot.state {
        case .booting: return "starting"
        case .failed: return "computer failed"
        case .suspended: return "paused"
        case .noSandbox: return "no computer"
        case .running: return "idle"
        }
    }

    static func outcomeLabel(_ outcome: String) -> String {
        [
            "auto": "Ran without asking", "reviewer_auto": "Approved by the reviewer", "approved": "Approved by you",
            "denied_by_user": "Denied by you", "denied": "Blocked by guardrails", "yolo_auto": "Ran (YOLO mode)",
            "granted_binary": "Ran (standing grant)", "granted_blanket": "Ran (allow all shell)", "quarantined": "Held for review",
            "approval_expired": "Approval expired", "approval_stale": "Approval went stale", "tripwire": "Tripwire",
        ][outcome] ?? outcome
    }

    static func count(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 10_000 ? String(format: "%.0fk", Double(n) / 1e3)
            : n >= 1_000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0f s", seconds) : seconds < 3_600 ? "\(Int(seconds / 60)) min" : String(format: "%.1f h", seconds / 3_600)
    }

    static func ago(_ seconds: Double) -> String { seconds < 5 ? "now" : duration(seconds) + " ago" }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .memory) }

    static func fileStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f.string(from: Date())
    }

    /// The same report as Markdown, for Export.
    static func report(_ s: TelemetryRecorder.Snapshot, bots: [Bot], loaded: [OllamaBackend.LoadedModel]) -> String {
        let t = s.total
        var out = "# Shellhouse telemetry\n\nSince \(s.startedAt.formatted()) · exported \(Date().formatted())\n\n"
        out += "## Totals\n\n| | |\n|---|---|\n"
        out += "| Model calls | \(t.calls) (\(t.failedCalls) failed) |\n| Tokens in / out | \(t.promptTokens) / \(t.completionTokens) |\n"
        out += "| Generation speed | \(t.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "—") |\n| Model time | \(duration(t.seconds)) |\n"
        out += "| Context window | \(OllamaBackend.contextWindowTokens) |\n\n"
        out += "## Bots\n\n| Bot | State | Model | Calls | Tokens in / out | Last context | Tools (failed) | Runs (stopped) | Compactions |\n|---|---|---|---|---|---|---|---|---|\n"
        for bot in bots {
            let b = s.byBot[bot.name] ?? TelemetryRecorder.BotStats()
            out += "| \(bot.name) | \(state(of: bot)) | \(bot.selectedModel) | \(b.model.calls) | \(b.model.promptTokens) / \(b.model.completionTokens) | "
                + "\(b.lastPromptTokens) | \(b.toolRuns) (\(b.toolFailures)) | \(b.runs) (\(b.runsStopped)) | \(b.compactions) |\n"
        }
        out += "\n## By purpose\n\n| Purpose | Calls | Tokens in / out | Time |\n|---|---|---|---|\n"
        for (key, v) in s.byPurpose.sorted(by: { $0.value.calls > $1.value.calls }) {
            out += "| \(key) | \(v.calls) | \(v.promptTokens) / \(v.completionTokens) | \(duration(v.seconds)) |\n"
        }
        out += "\n## By model\n\n| Model | Calls | Tokens in / out | Speed |\n|---|---|---|---|\n"
        for (key, v) in s.byModel.sorted(by: { $0.value.calls > $1.value.calls }) {
            out += "| \(key) | \(v.calls) | \(v.promptTokens) / \(v.completionTokens) | \(v.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "—") |\n"
        }
        out += "\n## Tools\n\n| Tool | Runs | Failed |\n|---|---|---|\n"
        for (key, v) in s.tools.sorted(by: { $0.value.runs > $1.value.runs }) { out += "| \(key) | \(v.runs) | \(v.failures) |\n" }
        out += "\n## Approvals\n\n"
        for (key, v) in s.approvals.sorted(by: { $0.value > $1.value }) { out += "- \(outcomeLabel(key)): \(v)\n" }
        if !s.stopReasons.isEmpty {
            out += "\n## Why runs stopped early\n\n"
            for (key, v) in s.stopReasons.sorted(by: { $0.value > $1.value }) { out += "- \(key): \(v)\n" }
        }
        if !loaded.isEmpty {
            out += "\n## Ollama models loaded\n\n"
            for m in loaded { out += "- \(m.name): \(bytes(m.sizeBytes)), context \(m.contextLength.map(String.init) ?? "?")\n" }
        }
        return out
    }
}
