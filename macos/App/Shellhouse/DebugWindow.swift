import AgentCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - What an entry is

/// What a debug entry is about, for color, filtering and layout. Derived from the raw entry (its kind, where it
/// came from, and how its text starts), so every caller of `DebugLog` gets it for free.
enum DebugCategory: String, CaseIterable, Identifiable {
    case you, reply, interBot, toolCall, toolResult, approval, error, progress, status, model, connection, system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .you: return "You"
        case .reply: return "Bot reply"
        case .interBot: return "Bot ↔ bot"
        case .toolCall: return "Tool call"
        case .toolResult: return "Tool result"
        case .approval: return "Approval"
        case .error: return "Error"
        case .progress: return "Progress"
        case .status: return "Status"
        case .model: return "Model"
        case .connection: return "Connection"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .you: return "person.fill"
        case .reply: return "text.bubble.fill"
        case .interBot: return "arrow.left.arrow.right.circle.fill"
        case .toolCall: return "hammer.fill"
        case .toolResult: return "arrow.turn.down.left"
        case .approval: return "checkmark.shield.fill"
        case .error: return "exclamationmark.octagon.fill"
        case .progress: return "ellipsis.circle"
        case .status: return "info.circle"
        case .model: return "cpu"
        case .connection: return "network"
        case .system: return "gearshape"
        }
    }

    var color: Color {
        switch self {
        case .you: return Color(hex: "#0A84FF")
        case .reply: return Color(hex: "#30D158")
        case .interBot: return Color(hex: "#BF5AF2")
        case .toolCall: return Color(hex: "#FF9F0A")
        case .toolResult: return Color(hex: "#64D2FF")
        case .approval: return Color(hex: "#FFD60A")
        case .error: return Color(hex: "#FF453A")
        case .progress: return Color(hex: "#8E8E93")
        case .status: return Color(hex: "#AC8E68")
        case .model: return Color(hex: "#5E5CE6")
        case .connection: return Color(hex: "#66D4CF")
        case .system: return Color(hex: "#98989D")
        }
    }

    /// Groups in the filter sidebar.
    static let groups: [(title: String, categories: [DebugCategory])] = [
        ("Conversation", [.you, .reply, .interBot]),
        ("Tools", [.toolCall, .toolResult]),
        ("Supervision", [.approval, .error]),
        ("Background", [.status, .progress, .model, .connection, .system]),
    ]
}

/// Tools whose call is one bot talking to another (or to a group).
private let interBotTools: Set<String> = ["message_bot", "post_to_group", "ask_helpers", "create_bot", "add_bot_to_group"]

extension DebugLogEntry {
    var category: DebugCategory {
        if kind == .error { return .error }
        if kind == .user { return .you }
        let ctx = (context ?? "").lowercased()
        if botName == "Connection" || ctx == "ssh tunnel" || ctx == "sandbox-manager" { return .connection }
        if botName == "Model" || ["scheduler", "fast model", "model"].contains(ctx) { return .model }
        if botName == "App" || ctx == "startup config" || ctx == "debug" { return .system }
        if kind == .tool, let tool = toolPayload {
            if interBotTools.contains(tool.name), tool.isCall { return .interBot }
            return tool.isCall ? .toolCall : .toolResult
        }
        if kind == .message { return ctx.hasPrefix("delegated from") ? .interBot : .reply }
        // status
        if text.hasPrefix("approval ") || ctx == "guardrails" || text.hasPrefix("reviewer ") { return .approval }
        if text.hasPrefix("Working…") || text == "Thinking…" || text == "Done" || text.hasPrefix("Waiting for your approval") { return .progress }
        return .status
    }

    /// "→ run_shell {…}" / "← run_shell: {…}", as logged by `Bot.logToDebugConsole`.
    var toolPayload: ToolPayload? { ToolPayload(text) }
}

struct ToolPayload {
    let isCall: Bool
    let name: String
    /// The JSON object, when it parses.
    let object: [String: Any]?
    let raw: String

    init?(_ text: String) {
        if text.hasPrefix("→ ") {
            isCall = true
            let rest = text.dropFirst(2)
            let name = rest.prefix { !$0.isWhitespace }
            self.name = String(name)
            raw = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("← ") {
            isCall = false
            let rest = text.dropFirst(2)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            name = String(rest[..<colon])
            raw = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        object = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

// MARK: - The window

/// The debug console, in a window of its own: every bot's activity with filters on the left (what kind of entry,
/// which bot, which conversation) and a readable, color-coded feed on the right.
struct DebugConsoleWindow: View {
    private var log = DebugLog.shared
    @Bindable private var settings = DebugSettings.shared

    @AppStorage("debug.hiddenCategories") private var hiddenRaw = "progress"
    /// Same appearance as the main window (Settings › General › Appearance).
    @AppStorage("appearanceMode") private var appearanceMode = "dark"
    @State private var botFilter: Set<String> = []
    @State private var contextFilter: String?
    @State private var search = ""
    @State private var follow = true
    @State private var showActivity = true

    private var hidden: Set<DebugCategory> {
        Set(hiddenRaw.split(separator: ",").compactMap { DebugCategory(rawValue: String($0)) })
    }
    private func setHidden(_ category: DebugCategory, _ isHidden: Bool) {
        var set = hidden
        if isHidden { set.insert(category) } else { set.remove(category) }
        hiddenRaw = set.map(\.rawValue).sorted().joined(separator: ",")
    }

    private var bots: [Bot] { BotDirectory.main?.allBots() ?? [] }

    private var sourceNames: [String] {
        var seen = Set<String>(); var out: [String] = []
        for entry in log.entries where seen.insert(entry.botName).inserted { out.append(entry.botName) }
        return out
    }

    /// "chat: X", "group: Y", "delegated from Z"… grouped by what kind of conversation it is.
    private var contexts: [String] {
        var seen = Set<String>(); var out: [String] = []
        for entry in log.entries {
            let key = Self.contextKey(entry.context)
            if seen.insert(key).inserted { out.append(key) }
        }
        return out.sorted()
    }

    static func contextKey(_ context: String?) -> String {
        guard let context, !context.isEmpty else { return "1:1 chat" }
        return context
    }

    private var filtered: [DebugLogEntry] {
        let hidden = self.hidden
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return log.entries.filter { entry in
            guard !hidden.contains(entry.category) else { return false }
            if !botFilter.isEmpty, !botFilter.contains(entry.botName) { return false }
            if let contextFilter, Self.contextKey(entry.context) != contextFilter { return false }
            if !query.isEmpty {
                let haystack = (entry.text + " " + entry.botName + " " + (entry.context ?? "")).lowercased()
                guard haystack.contains(query) else { return false }
            }
            return true
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
            VStack(spacing: 0) {
                toolbar
                Divider()
                if showActivity, !bots.isEmpty {
                    BotActivityPanel(bots: bots)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider()
                }
                feed
            }
            .frame(minWidth: 520)
        }
        .background(Theme.bg)
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle("Debug Console")
        .tint(Theme.accent)
        .preferredColorScheme(appearanceMode == "light" ? .light : (appearanceMode == "dark" ? .dark : nil))
    }

    // MARK: Sidebar filters

    private var sidebar: some View {
        let counts = Dictionary(grouping: log.entries, by: \.category).mapValues(\.count)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !settings.isEnabled {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(Theme.warning)
                        Text("Debug mode is off, so nothing new is logged.").font(.system(size: 12))
                    }
                    Button("Turn on debug mode") { settings.isEnabled = true }.controlSize(.small)
                }
                ForEach(DebugCategory.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(group.categories) { category in
                            categoryRow(category, count: counts[category] ?? 0)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("BOTS AND SOURCES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !botFilter.isEmpty { Button("All") { botFilter = [] }.buttonStyle(.link).font(.system(size: 11)) }
                    }
                    ForEach(sourceNames, id: \.self) { name in sourceRow(name) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONVERSATION").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("Conversation", selection: $contextFilter) {
                        Text("All conversations").tag(String?.none)
                        ForEach(contexts, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                }
            }
            .padding(14)
        }
        .background(Theme.card)
    }

    private func categoryRow(_ category: DebugCategory, count: Int) -> some View {
        let isOn = !hidden.contains(category)
        return Button { setHidden(category, isOn) } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? category.color : .secondary)
                Image(systemName: category.symbol).foregroundStyle(category.color).frame(width: 16)
                Text(category.label).foregroundStyle(isOn ? .primary : .secondary)
                Spacer()
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ name: String) -> some View {
        let color = log.entries.last(where: { $0.botName == name }).map { Color(hex: $0.botColorHex) } ?? .secondary
        let isOn = botFilter.isEmpty || botFilter.contains(name)
        return Button {
            if botFilter.contains(name) { botFilter.remove(name) } else { botFilter.insert(name) }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(name).foregroundStyle(isOn ? .primary : .secondary)
                Spacer()
                if botFilter.contains(name) { Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(color) }
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(botFilter.isEmpty ? "Show only \(name)" : (botFilter.contains(name) ? "Stop filtering on \(name)" : "Also show \(name)"))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, bots, conversations", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            // A definite width range: an open-ended one made AppKit's text field log min/max conflicts on every layout.
            .frame(minWidth: 200, idealWidth: 320, maxWidth: 420)
            .fixedSize(horizontal: false, vertical: true)
            Text("\(filtered.count) of \(log.entries.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).help("Keep scrolled to the newest entry")
            Toggle("Activity", isOn: $showActivity).toggleStyle(.checkbox).help("Show what each bot is doing right now")
            Button { copy(filtered) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(filtered.isEmpty).help("Copy what's shown (with the filters applied)")
            Button { export(filtered) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .disabled(filtered.isEmpty)
            Button(role: .destructive) { log.clear() } label: { Label("Clear", systemImage: "trash") }
                .disabled(log.entries.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Feed

    private var feed: some View {
        let entries = filtered
        return Group {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(log.entries.isEmpty ? "Nothing yet. This fills in as bots work." : "Nothing matches these filters.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { entry in DebugEntryCard(entry: entry).id(entry.id) }
                        }
                        .padding(14)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: entries.last?.id) { _, last in
                        if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: Copy / export

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f
    }()

    private func plainText(_ entries: [DebugLogEntry]) -> String {
        entries.map { entry in
            "\(Self.timeFormatter.string(from: entry.timestamp))  \(entry.botName)\(entry.context.map { " (\($0))" } ?? "")  [\(entry.category.label)]\n\(entry.text)"
        }.joined(separator: "\n\n")
    }

    private func copy(_ entries: [DebugLogEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(entries), forType: .string)
    }

    private func export(_ entries: [DebugLogEntry]) {
        let text = plainText(entries)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "debug-console-\(Int(Date().timeIntervalSince1970)).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - One entry

private struct DebugEntryCard: View {
    let entry: DebugLogEntry
    @State private var expanded = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f
    }()

    var body: some View {
        let category = entry.category
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(category.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                header(category)
                content(category)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .background(category == .progress ? Color.clear : Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(category.color.opacity(category == .error ? 0.6 : 0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }

    private func header(_ category: DebugCategory) -> some View {
        HStack(spacing: 8) {
            Label(category.label, systemImage: category.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(category.color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(category.color.opacity(0.14), in: Capsule())
            HStack(spacing: 5) {
                Circle().fill(Color(hex: entry.botColorHex)).frame(width: 8, height: 8)
                Text(entry.botName).font(.system(size: 12, weight: .semibold))
            }
            if let context = entry.context, !context.isEmpty {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
            }
            if entry.isStreaming { ProgressView().controlSize(.mini) }
            Spacer()
            Text(Self.timeFormatter.string(from: entry.timestamp)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func content(_ category: DebugCategory) -> some View {
        if let tool = entry.toolPayload {
            ToolPayloadView(tool: tool, color: category.color, expanded: $expanded)
        } else if entry.text.hasPrefix("approval ") {
            ApprovalTextView(text: entry.text)
        } else if category == .progress {
            Text(entry.text).font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            LongText(text: entry.text.isEmpty ? "…" : entry.text,
                     monospaced: category == .system || category == .connection,
                     color: category == .error ? DebugCategory.error.color : .primary,
                     expanded: $expanded)
        }
    }
}

/// Body text with a "Show all" after a dozen lines.
private struct LongText: View {
    let text: String
    var monospaced = false
    var color: Color = .primary
    @Binding var expanded: Bool
    private let limit = 12

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 4) {
            Text(expanded || lines.count <= limit ? text : lines.prefix(limit).joined(separator: "\n"))
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(color)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if lines.count > limit {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }
}

/// A tool call (its arguments, laid out) or a tool result (exit status, output, hints).
private struct ToolPayloadView: View {
    let tool: ToolPayload
    let color: Color
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(tool.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(color)
                if !tool.isCall, let exit = tool.object?["exit_code"] as? Int {
                    statusBadge(exit == 0 ? "exit 0" : "exit \(exit)", ok: exit == 0)
                }
                if !tool.isCall, tool.object?["error"] != nil { statusBadge("failed", ok: false) }
                if !tool.isCall, tool.object?["held_for_review"] != nil { statusBadge("held for review", ok: true) }
            }
            if let object = tool.object {
                if tool.isCall { callBody(object) } else { resultBody(object) }
            } else if !tool.raw.isEmpty {
                CodeBlock(text: tool.raw, expanded: $expanded)
            }
        }
    }

    private func statusBadge(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(ok ? DebugCategory.reply.color : DebugCategory.error.color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((ok ? DebugCategory.reply.color : DebugCategory.error.color).opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private func callBody(_ object: [String: Any]) -> some View {
        // The main argument gets a code block; the rest are short key: value lines.
        let primaryKeys = ["command", "message", "content", "new_text", "text", "url", "query", "instruction"]
        let primary = primaryKeys.first { object[$0] is String }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(object.keys.filter { $0 != primary && !$0.hasPrefix("_") }.sorted(), id: \.self) { key in
                KeyValueLine(key: key, value: Self.short(object[key]))
            }
            if let primary, let text = object[primary] as? String {
                if primary != "command" { Text(primary).font(.system(size: 11)).foregroundStyle(.secondary) }
                CodeBlock(text: text, expanded: $expanded)
            }
        }
    }

    @ViewBuilder
    private func resultBody(_ object: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error = object["error"] as? String { Callout(text: error, symbol: "xmark.octagon.fill", color: DebugCategory.error.color) }
            ForEach(["hint", "warning", "note"], id: \.self) { key in
                if let text = object[key] as? String { Callout(text: text, symbol: "lightbulb.fill", color: DebugCategory.approval.color) }
            }
            if let stdout = object["stdout"] as? String, !stdout.isEmpty { CodeBlock(text: stdout, expanded: $expanded) }
            if let stderr = object["stderr"] as? String, !stderr.isEmpty {
                Text("stderr").font(.system(size: 11)).foregroundStyle(.secondary)
                CodeBlock(text: stderr, tint: DebugCategory.error.color, expanded: $expanded)
            }
            if let content = object["content"] as? String { CodeBlock(text: content, expanded: $expanded) }
            let shown: Set<String> = ["error", "hint", "warning", "note", "stdout", "stderr", "content", "exit_code"]
            ForEach(object.keys.filter { !shown.contains($0) && !$0.hasPrefix("_") }.sorted(), id: \.self) { key in
                KeyValueLine(key: key, value: Self.short(object[key]))
            }
        }
    }

    static func short(_ value: Any?) -> String {
        switch value {
        case let s as String: return s.count > 300 ? String(s.prefix(300)) + "…" : s
        case let b as Bool: return b ? "yes" : "no"
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { short($0) }.joined(separator: ", ")
        case let d as [String: Any]:
            return (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 } ?? ""
        case nil: return ""
        default: return "\(value!)"
        }
    }
}

private struct KeyValueLine: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CodeBlock: View {
    let text: String
    var tint: Color = .primary
    @Binding var expanded: Bool
    private let limit = 14

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 4) {
            Text(expanded || lines.count <= limit ? text : lines.prefix(limit).joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            if lines.count > limit {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }
}

private struct Callout: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 12))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// "approval decision: run_shell — ran (YOLO) · changes directory · {"command":…}" laid out as a title, the
/// reasons, and the command.
private struct ApprovalTextView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        let parts = text.components(separatedBy: " · ")
        let title = parts.first ?? text
        let json = parts.dropFirst().last.flatMap { $0.hasPrefix("{") ? $0 : nil }
        let reasons = parts.dropFirst().filter { $0 != json }
        let command = json.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["command"] as? String) ?? ToolPayloadView.short($0) }
        VStack(alignment: .leading, spacing: 5) {
            Text(title.replacingOccurrences(of: "approval decision: ", with: "").replacingOccurrences(of: "approval prompt: ", with: "Asked you: "))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(title.contains("blocked") || title.contains("denied") ? DebugCategory.error.color : .primary)
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                Label(reason, systemImage: "smallcircle.filled.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let command { CodeBlock(text: command, expanded: $expanded) }
        }
    }
}
