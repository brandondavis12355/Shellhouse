import AgentCore
import SwiftUI

/// A settings file waiting to be imported: what it would change, and what in it doesn't fit this version.
struct ImportReview: Identifiable {
    let id = UUID()
    let url: URL
    let contents: SettingsBundle.Contents
    let issues: [SettingsBundle.Issue]
    /// macOS marks the file as downloaded.
    let downloaded: Bool
    /// Overwrite the file with a receipt afterwards (files handed to the app from outside).
    let receipt: Bool
    /// Already applied (a file the setup scripts handed over): the sheet just shows the result.
    var alreadyImported = false
}

/// Review, then result, of a settings import, in the same style as Settings: what changes, what doesn't fit this
/// version (and what happens to it instead), then Import / Import what fits, or Cancel to start over.
struct ImportReviewSheet: View {
    let review: ImportReview
    let onImport: () async -> Void
    let onClose: () -> Void

    private enum Phase { case review, importing, done }
    @State private var phase: Phase

    init(review: ImportReview, onImport: @escaping () async -> Void, onClose: @escaping () -> Void) {
        self.review = review
        self.onImport = onImport
        self.onClose = onClose
        _phase = State(initialValue: review.alreadyImported ? .done : .review)
    }

    private var contents: SettingsBundle.Contents { review.contents }
    private var skipped: Int { review.issues.filter { $0.kind == .skipped }.count }
    private var filled: Int { review.issues.filter { $0.kind == .filled }.count }

    var body: some View {
        SheetScaffold(title: phase == .done ? "Settings imported" : "Import settings",
                      subtitle: review.url.lastPathComponent, onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                if phase == .done { doneBanner } else {
                    if review.downloaded { downloadedCallout }
                    changes
                    if !review.issues.isEmpty { issuesSection }
                }
            }
        } footer: {
            SheetFooter {
                switch phase {
                case .review:
                    Button("Cancel", action: onClose)
                        .buttonStyle(.pill)
                        .keyboardShortcut(.cancelAction)
                    Button(review.issues.isEmpty ? "Import" : "Import what fits") {
                        phase = .importing
                        Task { @MainActor in await onImport(); phase = .done }
                    }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                case .importing:
                    ProgressView().controlSize(.small)
                    Text("Importing…").foregroundStyle(.secondary)
                case .done:
                    Button("Done", action: onClose)
                        .buttonStyle(.primaryPill)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 560, height: review.issues.isEmpty && phase != .done ? 470 : 680)
    }

    // MARK: Review

    private var downloadedCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 18)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("This file was downloaded").font(.system(size: 14, weight: .semibold))
                Text("Only import settings from someone you trust: a settings file can point the app at a different Linux host.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .padding(.top, 8)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "What changes", symbol: "square.and.arrow.down",
                                detail: "Only what's listed here changes. Conversations and memories are never in a settings file.")
            Card {
                let rows = changeRows
                if rows.isEmpty {
                    row(symbol: "tray", color: .secondary, title: "Nothing to import", value: "This file has no settings this version can use")
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                    if index > 0 { CardDivider(inset: 52) }
                    row(symbol: item.symbol, color: item.color, title: item.title, value: item.value)
                }
            }
        }
    }

    private var changeRows: [(symbol: String, color: Color, title: String, value: String)] {
        var rows: [(String, Color, String, String)] = []
        if let host = contents.host { rows.append(("server.rack", Theme.accent, "Linux host", host)) }
        let appCount = contents.app.count - (contents.host == nil ? 0 : 1)
        if appCount > 0 { rows.append(("gearshape.fill", Color(hex: "#8E8E93"), "App settings", "\(appCount) setting\(appCount == 1 ? "" : "s")")) }
        if !contents.bots.isEmpty { rows.append(("person.2.fill", Color(hex: "#30D158"), "Bots", Self.names(contents.bots.map(\.name)))) }
        if !contents.groups.isEmpty { rows.append(("bubble.left.and.bubble.right.fill", Color(hex: "#BF5AF2"), "Groups", Self.names(contents.groups.map(\.name)))) }
        if !contents.knownHosts.isEmpty {
            rows.append(("lock.shield.fill", Color(hex: "#30D158"), "SSH host key", "Verified; only this key is accepted"))
        }
        if !contents.secrets.isEmpty {
            rows.append(("key.fill", Color(hex: "#FFD60A"), "Secrets", "\(contents.secrets.count) saved to the Keychain"))
        }
        return rows
    }

    private static func names(_ names: [String]) -> String {
        names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }

    private func row(symbol: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title).font(.system(size: 15))
            Spacer(minLength: 12)
            Text(value).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Doesn't fit this version", symbol: "exclamationmark.triangle",
                                detail: "Each item says what happens instead. Import what fits and fill in the rest in Settings, or cancel to start over with another file.")
            HStack(spacing: 8) {
                if skipped > 0 { tally("\(skipped) skipped", kind: .skipped) }
                if filled > 0 { tally("\(filled) use a default", kind: .filled) }
            }
            .padding(.bottom, 8).padding(.horizontal, 4)
            Card {
                ForEach(Array(review.issues.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 { CardDivider(inset: 44) }
                    IssueRow(issue: issue)
                }
            }
        }
    }

    private func tally(_ text: String, kind: SettingsBundle.Issue.Kind) -> some View {
        Label(text, systemImage: IssueRow.symbol(kind))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(IssueRow.color(kind))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(IssueRow.color(kind).opacity(0.14), in: Capsule())
    }

    // MARK: Done

    private var doneBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.positive)
                .padding(.top, 34)
            Text("Everything in the file that fits is applied").font(.system(size: 17, weight: .semibold))
            Text("It takes effect now: no restart needed.").font(.system(size: 13)).foregroundStyle(.secondary)
            if skipped + filled > 0 {
                Text("\(skipped + filled) item\(skipped + filled == 1 ? " was" : "s were") skipped or set to a default. Check Settings for those.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            changes.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct IssueRow: View {
    let issue: SettingsBundle.Issue

    static func symbol(_ kind: SettingsBundle.Issue.Kind) -> String {
        switch kind {
        case .skipped: return "minus.circle.fill"
        case .filled: return "arrow.uturn.backward.circle.fill"
        case .note: return "info.circle.fill"
        }
    }

    static func color(_ kind: SettingsBundle.Issue.Kind) -> Color {
        switch kind {
        case .skipped: return Color(hex: "#FF9F0A")
        case .filled: return Color(hex: "#0A84FF")
        case .note: return Color(hex: "#8E8E93")
        }
    }

    private var label: String {
        switch issue.kind {
        case .skipped: return "Skipped"
        case .filled: return "Default used"
        case .note: return "Note"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(issue.kind))
                .font(.system(size: 15))
                .foregroundStyle(Self.color(issue.kind))
                .frame(width: 20)
            Text(issue.text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Self.color(issue.kind))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Self.color(issue.kind).opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
