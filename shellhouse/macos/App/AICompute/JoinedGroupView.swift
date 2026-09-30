import AgentCore
import SwiftUI

/// A group someone else owns and invited this user to: read the chat (their
/// bots' replies included) and post. There are no bots of this user's here and
/// nothing from this Mac is shared — only what they type.
@MainActor
@Observable
final class JoinedGroupSession: Identifiable {
    nonisolated let id: String
    let groupID: String
    var name: String
    let ownerID: String

    private(set) var log = JoinedGroupLog()
    private(set) var members: [RelayFriend] = []
    private(set) var ended = false
    private(set) var connectionNote = ""
    var input = ""
    private(set) var isSending = false
    var error: String?
    private(set) var lastReadSeq: Int

    private var stream: RelayMessageStream?
    private weak var client: RelayClient?
    private(set) var myUserID = ""
    private var lastReadKey: String { "joinedGroup.lastRead.\(groupID)" }

    var messages: [RelayMessage] { log.messages }
    var ownerName: String { members.first { $0.userId == ownerID }?.displayName ?? "the owner" }
    var unreadCount: Int { log.unreadCount(after: lastReadSeq, myUserID: myUserID) }

    init(summary: RelayGroupSummary) {
        id = summary.groupId
        groupID = summary.groupId
        name = summary.name
        ownerID = summary.ownerId
        lastReadSeq = UserDefaults.standard.integer(forKey: "joinedGroup.lastRead.\(summary.groupId)")
    }

    func start(client: RelayClient) {
        guard stream == nil else { return }
        self.client = client
        myUserID = client.identity.userID
        let newStream = RelayMessageStream(
            client: client, groupID: groupID, after: 0,
            onMessages: { [weak self] batch in await MainActor.run { self?.receive(batch) } },
            onEnded: { [weak self] _ in await MainActor.run { self?.ended = true } },
            onConnectionChange: { [weak self] up in await MainActor.run { self?.connectionNote = up ? "" : "Reconnecting…" } }
        )
        stream = newStream
        newStream.start()
        Task { await loadMembers() }
    }

    func stop() {
        stream?.stop()
        stream = nil
    }

    private func receive(_ batch: [RelayMessage]) {
        let firstLoad = log.messages.isEmpty
        log.append(contentsOf: batch)
        // History that was already there when this app first saw the group
        // isn't "unread".
        if firstLoad && UserDefaults.standard.object(forKey: lastReadKey) == nil {
            markRead()
        }
    }

    func markRead() {
        lastReadSeq = log.latestSeq
        UserDefaults.standard.set(lastReadSeq, forKey: lastReadKey)
    }

    func loadMembers() async {
        guard let client else { return }
        if let detail = try? await client.group(groupID) { members = detail.members }
    }

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await client.postMessage(String(text.prefix(8000)), to: groupID)
            input = ""
            error = nil
        } catch {
            self.error = FriendsManager.describe(error)
        }
    }

    func leave() async -> Bool {
        guard let client else { return false }
        do {
            try await client.removeMember(myUserID, from: groupID)
            stop()
            ended = true
            return true
        } catch {
            self.error = FriendsManager.describe(error)
            return false
        }
    }
}

/// The groups this user has joined, kept in step with the relay.
@MainActor
@Observable
final class JoinedGroups {
    static let shared = JoinedGroups()
    private(set) var sessions: [JoinedGroupSession] = []
    var totalUnread: Int { sessions.reduce(0) { $0 + $1.unreadCount } }
    private init() {}

    /// Called after every friends refresh with the user's full group list.
    func sync(groups: [RelayGroupSummary], client: RelayClient) {
        let joined = JoinedGroupFilter.joined(groups, myUserID: client.identity.userID)
        let ids = Set(joined.map(\.groupId))
        for gone in sessions where !ids.contains(gone.groupID) || gone.ended {
            gone.stop()
            UserDefaults.standard.removeObject(forKey: "joinedGroup.lastRead.\(gone.groupID)")
        }
        sessions.removeAll { !ids.contains($0.groupID) || $0.ended }
        for summary in joined {
            if let existing = sessions.first(where: { $0.groupID == summary.groupId }) {
                existing.name = summary.name
            } else {
                let session = JoinedGroupSession(summary: summary)
                session.start(client: client)
                sessions.append(session)
            }
        }
    }

    func reset() {
        sessions.forEach { $0.stop() }
        sessions = []
    }
}

struct JoinedGroupSidebarRow: View {
    let session: JoinedGroupSession
    var body: some View {
        HStack {
            Image(systemName: "person.2.wave.2").foregroundStyle(.teal)
            Text(session.name).lineLimit(1)
            Spacer()
            if session.unreadCount > 0 {
                Text("\(session.unreadCount)")
                    .font(.caption2).bold().foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
            }
        }
    }
}

struct JoinedGroupView: View {
    @Bindable var session: JoinedGroupSession
    var onLeft: () -> Void = {}
    @State private var confirmLeave = false

    private var mentionColors: [String: String] {
        var colors: [String: String] = [:]
        for message in session.messages {
            let key = message.speakerName.lowercased()
            colors[key] = message.kind == .bot ? "#7c3aed" : "#14b8a6"
        }
        return colors
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "person.2.wave.2").imageScale(.large).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.name).font(.title2)
                    Text("Shared by \(session.ownerName) · \(session.members.count) people")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !session.connectionNote.isEmpty {
                    Text(session.connectionNote).font(.caption).foregroundStyle(.orange)
                }
                Menu {
                    ForEach(session.members) { member in Text(member.displayName) }
                    Divider()
                    Button("Leave group…", role: .destructive) { confirmLeave = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("The bots here belong to \(session.ownerName) and run on their computer. Everything you post is visible to everyone in the group.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if session.ended {
                Spacer()
                Text("You no longer have access to this group.").foregroundStyle(.secondary)
                Spacer()
            } else {
                transcript
                composer
            }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 500)
        .onAppear { session.markRead() }
        .onChange(of: session.messages.last?.seq) { _, _ in session.markRead() }
        .confirmationDialog("Leave “\(session.name)”?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave group", role: .destructive) {
                Task { if await session.leave() { onLeft() } }
            }
        } message: {
            Text("You'll stop seeing this chat. \(session.ownerName) can invite you again.")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { message in
                        JoinedMessageRow(message: message, isMine: message.kind == .human && message.speakerUserId == session.myUserID, mentionColors: mentionColors)
                            .id(message.seq)
                    }
                }
                .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.messages.last?.seq) { _, last in
                if let last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom) {
                TextField("Message the group… (@mention a bot to call on it)", text: $session.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16))
                    .onSubmit { Task { await session.send() } }
                Button(session.isSending ? "Sending…" : "Send") { Task { await session.send() } }
                    .disabled(session.input.trimmingCharacters(in: .whitespaces).isEmpty || session.isSending)
                    .font(.system(size: 16))
                    .controlSize(.large)
            }
        }
    }
}

private struct JoinedMessageRow: View {
    let message: RelayMessage
    let isMine: Bool
    let mentionColors: [String: String]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    private var color: Color {
        switch message.kind {
        case .bot: return Color(hex: "#7c3aed")
        case .system: return .gray
        case .human: return isMine ? .blue : .teal
        }
    }

    var body: some View {
        if message.kind == .system {
            Text(message.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                if isMine { Spacer(minLength: 48) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(isMine ? "You" : message.speakerName)
                            .font(.caption2).fontWeight(.semibold).foregroundStyle(color)
                        if message.kind == .bot {
                            Text("bot").font(.caption2)
                                .padding(.horizontal, 5)
                                .background(color.opacity(0.2), in: Capsule())
                                .foregroundStyle(color)
                        }
                        Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: message.ts)))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    MentionPillText(text: message.text, mentionColors: mentionColors).textSelection(.enabled)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(color.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if !isMine { Spacer(minLength: 48) }
            }
        }
    }
}
