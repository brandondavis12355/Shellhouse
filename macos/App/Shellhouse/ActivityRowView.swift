import AgentCore
import SwiftUI

/// What a bot did on the way to its answer, as one row instead of a bubble per step. Live: a spinner and the current
/// step on one line. Done: "Done in 38 s · 12 steps" with small counts (clicks, typing, screenshots). Tap to open the
/// step list: each tool with a ✓ or ✗, and the short notes the bot wrote between calls. Display only: the messages,
/// the saved transcript and the model's prompt are unchanged.
struct ActivityRowView: View {
    let steps: [DisplayMessage]
    let isLive: Bool
    let liveStatus: String
    @State private var isExpanded = false

    private var tools: [DisplayMessage] { steps.filter { $0.role == .tool } }
    private var failed: Int { tools.filter(Self.isFailure).count }

    static func isFailure(_ message: DisplayMessage) -> Bool {
        let t = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{\"error\"") || t.hasPrefix("Error")
    }

    static func symbol(for tool: String) -> String {
        switch tool {
        case "click", "move_mouse", "scroll": return "cursorarrow.click"
        case "type_text", "type_secret", "press_key": return "keyboard"
        case "screenshot", "list_windows", "focus_window": return "camera.viewfinder"
        case "open_app": return "macwindow"
        case "run_shell", "check_job", "stop_job": return "terminal"
        case "read_file", "write_file", "edit_file", "search_files", "find_files", "list_files": return "doc.text"
        case "fetch_url", "web_search": return "globe"
        case "remember", "recall_memory", "replace_memory": return "brain"
        default: return "wrench.and.screwdriver"
        }
    }

    /// "4 clicks", "2 typed", "5 screenshots", "3 commands" … by kind, in a fixed order, so the chips read the same every time.
    private var counts: [(symbol: String, label: String)] {
        let groups: [(String, String, Set<String>)] = [
            ("cursorarrow.click", "click", ["click", "move_mouse", "scroll"]),
            ("keyboard", "typed", ["type_text", "type_secret", "press_key"]),
            ("camera.viewfinder", "screenshot", ["screenshot", "list_windows", "focus_window"]),
            ("terminal", "command", ["run_shell", "check_job", "stop_job"]),
            ("doc.text", "file step", ["read_file", "write_file", "edit_file", "search_files", "find_files", "list_files"]),
            ("globe", "web", ["fetch_url", "web_search", "open_app"]),
        ]
        var used = Set<String>()
        var out: [(String, String)] = []
        for (symbol, word, names) in groups {
            let n = tools.filter { names.contains($0.toolName ?? "") }.count
            used.formUnion(names)
            guard n > 0 else { continue }
            out.append((symbol, word == "typed" || word == "web" ? "\(n) \(word)" : "\(n) \(word)\(n == 1 ? "" : "s")"))
        }
        let other = tools.filter { !used.contains($0.toolName ?? "") }.count
        if other > 0 { out.append(("wrench.and.screwdriver", "\(other) other")) }
        return out
    }

    private var title: String {
        if isLive { return "Working…" }
        let seconds = Int((steps.last?.timestamp ?? Date()).timeIntervalSince(steps.first?.timestamp ?? Date()))
        let time = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(max(seconds, 1)) s"
        return failed > 0 ? "Done in \(time) · \(failed) failed" : "Done in \(time)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if isLive {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                    } else {
                        Image(systemName: failed > 0 ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(failed > 0 ? Theme.warning : Theme.positive)
                    }
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text("\(tools.count) step\(tools.count == 1 ? "" : "s")").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isLive, !liveStatus.isEmpty {
                Text(liveStatus).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !counts.isEmpty {
                HStack(spacing: 6) {
                    ForEach(counts, id: \.label) { item in
                        Label(item.label, systemImage: item.symbol)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.chip, in: Capsule())
                    }
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps) { step in stepLine(step) }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.bubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
    }

    @ViewBuilder private func stepLine(_ step: DisplayMessage) -> some View {
        if step.role == .tool {
            let bad = Self.isFailure(step)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.symbol(for: step.toolName ?? "")).font(.system(size: 11)).frame(width: 14).foregroundStyle(.secondary)
                Text(step.toolName ?? "tool").font(.system(size: 12, design: .monospaced))
                Image(systemName: bad ? "xmark" : "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(bad ? Theme.destructive : Theme.positive)
                if bad {
                    Text(String(step.text.prefix(140))).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else if !step.text.isEmpty {
            Text(step.text).font(.system(size: 12)).italic().foregroundStyle(.tertiary).lineLimit(2)
                .padding(.leading, 20)
        }
    }
}
