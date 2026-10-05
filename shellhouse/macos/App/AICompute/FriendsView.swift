import AgentCore
import AppKit
import SwiftUI

/// App-wide state for the friends system: the relay connection settings, this
/// installation's identity, and the friend/request lists. One shared instance
/// so the sidebar badge and the Friends sheet agree.
@MainActor
@Observable
final class FriendsManager {
    static let shared = FriendsManager()

    enum Phase: Equatable {
        case notConfigured, connecting, connected
        case failed(String)
    }

    private static let settingsKey = "relaySettings.v1"
    private static let tokenSecretName = "RELAY_REGISTRATION_TOKEN"

    var settings: RelaySettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        }
    }
    private(set) var phase: Phase = .notConfigured
    private(set) var friends: [RelayFriend] = []
    private(set) var incoming: [RelayFriend] = []
    private(set) var outgoing: [RelayFriend] = []
    private(set) var inviteCode: String?
    private(set) var inviteCreatedAt: Date?
    private(set) var myUserID: String?
    private(set) var tokenIsSet = false
    /// One-line result of the last action (success or problem).
    var notice: (text: String, isError: Bool)?
    private(set) var isBusy = false

    private(set) var client: RelayClient?
    /// Fired after every successful (re)connect / on disconnect, so shared
    /// groups can restart or stop their live sync.
    var onConnected: () -> Void = {}
    var onDisconnected: () -> Void = {}
    private var refreshTask: Task<Void, Never>?
    private let keyStore = KeychainRelayKeyStore()

    var incomingCount: Int { incoming.count }
    var isConnected: Bool { phase == .connected }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(RelaySettings.self, from: data) {
            settings = saved
        } else {
            settings = RelaySettings()
        }
    }

    // MARK: Connection

    func connectIfConfigured() async {
        tokenIsSet = ((try? await SecretStore().resolveOne(name: Self.tokenSecretName)) ?? nil) != nil
        guard settings.isComplete else { return }
        await connect()
    }

    func connect() async {
        guard phase != .connecting else { return }   // one connect at a time
        let problems = settings.problems
        guard problems.isEmpty else {
            phase = .failed(problems.joined(separator: " "))
            return
        }
        // Reconnecting (possibly to a different relay): drop every stream that
        // still holds the old client before building the new one.
        if client != nil {
            onDisconnected()
            JoinedGroups.shared.reset()
        }
        phase = .connecting
        notice = nil
        do {
            let token = try await SecretStore().resolveOne(name: Self.tokenSecretName)
            tokenIsSet = token != nil
            let identity = try await RelayIdentityStore.loadOrCreate(in: keyStore)
            let newClient = try RelayClient(config: settings.config(registrationToken: token), identity: identity)
            try await newClient.register(displayName: RelaySettings.cleanDisplayName(settings.displayName))
            client = newClient
            myUserID = identity.userID
            phase = .connected
            await refresh()
            onConnected()
        } catch {
            client = nil
            onDisconnected()
            JoinedGroups.shared.reset()
            phase = .failed(Self.describe(error))
        }
    }

    func saveRegistrationToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try await SecretStore().delete(name: Self.tokenSecretName)
                tokenIsSet = false
            } else {
                try await SecretStore().put(name: Self.tokenSecretName, value: trimmed, notes: "Group relay registration token")
                tokenIsSet = true
            }
        } catch {
            notice = (Self.describe(error), true)
        }
    }

    func disconnect() {
        stopAutoRefresh()
        client = nil
        onDisconnected()
        JoinedGroups.shared.reset()
        friends = []; incoming = []; outgoing = []
        inviteCode = nil
        phase = .notConfigured
    }

    // MARK: Lists

    func refresh() async {
        guard let client else { return }
        do {
            let list = try await client.friends()
            friends = list.friends
            incoming = list.incoming
            outgoing = list.outgoing
            // Groups friends have invited me to (and ones I've left or been removed from).
            if let groups = try? await client.groups(), self.client === client {
                JoinedGroups.shared.sync(groups: groups, client: client)
            }
        } catch {
            notice = (Self.describe(error), true)
        }
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: Actions

    private func perform(success: String? = nil, _ action: (RelayClient) async throws -> Void) async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await action(client)
            if let success { notice = (success, false) }
            await refresh()
        } catch {
            notice = (Self.describe(error), true)
        }
    }

    func createInvite() async {
        await perform { client in
            self.inviteCode = try await client.createInvite()
            self.inviteCreatedAt = Date()
        }
    }

    func redeem(code: String) async -> Bool {
        var redeemed = false
        await perform { client in
            let result = try await client.redeemInvite(code: code)
            self.notice = result.status == "accepted"
                ? ("You and \(result.friend.displayName) both invited each other — you're now friends.", false)
                : ("Request sent to \(result.friend.displayName). They need to accept it.", false)
            redeemed = true
        }
        return redeemed
    }

    func accept(_ friend: RelayFriend) async {
        await perform(success: "\(friend.displayName) is now your friend.") { try await $0.acceptFriend(friend.userId) }
    }

    func decline(_ friend: RelayFriend) async {
        await perform(success: "Request declined.") { try await $0.declineFriend(friend.userId) }
    }

    func cancelRequest(_ friend: RelayFriend) async {
        await perform(success: "Request to \(friend.displayName) cancelled.") { try await $0.removeFriend(friend.userId) }
    }

    func remove(_ friend: RelayFriend) async {
        await perform(success: "\(friend.displayName) was removed from your friends and your shared groups.") {
            try await $0.removeFriend(friend.userId)
        }
    }

    func block(_ friend: RelayFriend) async {
        await perform(success: "\(friend.displayName) is blocked.") { try await $0.block(friend.userId) }
    }

    // MARK: Errors

    static func describe(_ error: Error) -> String {
        if let relay = error as? RelayError {
            if case .transport(let detail) = relay {
                if detail.localizedCaseInsensitiveContains("TLS") || detail.localizedCaseInsensitiveContains("secure connection") {
                    return "Couldn't make a secure connection. The certificate fingerprint doesn't match the relay's, or the relay isn't serving TLS."
                }
                return "Couldn't reach the relay (\(detail)). Are you on the same network as the host?"
            }
            if case .http(let status, let detail) = relay, status == 403, detail.contains("registration token") {
                return "The relay requires a registration token. Ask the relay's owner for it."
            }
            return relay.localizedDescription
        }
        return error.localizedDescription
    }
}

/// Settings sheet: connect to a relay, invite people, accept requests.
struct FriendsView: View {
    @Bindable private var manager = FriendsManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput = ""
    @State private var redeemCode = ""
    @State private var pendingRemoval: RelayFriend?
    @State private var pendingBlock: RelayFriend?
    @State private var showConnection = false

    var body: some View {
        SheetScaffold(title: "Friends") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    statusPill
                }
                .padding(.horizontal, 16)

                if let notice = manager.notice {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(notice.isError ? Theme.warning : Theme.positive)
                        Text(notice.text).font(.system(size: 13))
                        Spacer()
                        Button { manager.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                        .strokeBorder((notice.isError ? Theme.warning : Theme.positive).opacity(0.5), lineWidth: 1))
                    .padding(.top, 8)
                }

                connectionSection

                if manager.isConnected {
                    inviteSection
                    addFriendSection
                    requestsSection
                    friendsSection
                }
            }
        } footer: {
            SheetFooter {
                Button("Done") { dismiss() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520, height: 680)
        .task {
            showConnection = !manager.isConnected
            if manager.phase == .notConfigured { await manager.connectIfConfigured() }
            manager.startAutoRefresh()
            await manager.refresh()
        }
        .confirmationDialog("Remove \(pendingRemoval?.displayName ?? "friend")?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let friend = pendingRemoval { Task { await manager.remove(friend) } }
                pendingRemoval = nil
            }
        } message: {
            Text("They're removed from your friends and from any of your shared groups. They can be invited again later.")
        }
        .confirmationDialog("Block \(pendingBlock?.displayName ?? "user")?", isPresented: Binding(
            get: { pendingBlock != nil }, set: { if !$0 { pendingBlock = nil } }
        ), titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let friend = pendingBlock { Task { await manager.block(friend) } }
                pendingBlock = nil
            }
        } message: {
            Text("They're removed from your friends and groups and can't send you requests or redeem your invites.")
        }
    }

    // MARK: Sections

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch manager.phase {
            case .notConfigured: return ("Not connected", .gray)
            case .connecting: return ("Connecting…", .yellow)
            case .connected: return ("Connected", Theme.positive)
            case .failed: return ("Can't connect", Theme.warning)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableCard("Relay connection", summary: manager.isConnected ? "Connected" : nil, startsExpanded: showConnection) {
                Text("The relay is a small service running on your network that friends' apps share. Ask whoever runs it for its address and certificate fingerprint.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("Relay address (e.g. 10.0.0.5 or relay.lan:8443)", text: $manager.settings.address)
                    .themedField()
                TextField("Certificate fingerprint (SHA-256)", text: $manager.settings.fingerprint)
                    .themedField()
                    .font(.system(size: 13, design: .monospaced))
                if !manager.settings.fingerprint.isEmpty && !manager.settings.isFingerprintValid {
                    Text("That doesn't look like a SHA-256 fingerprint (64 hex characters).")
                        .font(.system(size: 13)).foregroundStyle(Theme.warning)
                }
                TextField("Your name (shown to friends)", text: $manager.settings.displayName)
                    .themedField()
                HStack {
                    SecureField(manager.tokenIsSet ? "Registration token (saved)" : "Registration token (if the relay needs one)", text: $tokenInput)
                        .themedField()
                    Button("Save") {
                        Task { await manager.saveRegistrationToken(tokenInput); tokenInput = "" }
                    }
                    .disabled(tokenInput.isEmpty)
                    if manager.tokenIsSet {
                        Button("Clear") { Task { await manager.saveRegistrationToken("") } }
                    }
                }
                if case .failed(let message) = manager.phase {
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.warning)
                }
                HStack {
                    Button(manager.isConnected ? "Reconnect" : "Connect") { Task { await manager.connect() } }
                        .buttonStyle(.primaryPill)
                        .disabled(!manager.settings.isComplete || manager.phase == .connecting)
                    if manager.isConnected {
                        Button("Disconnect") { manager.disconnect() }
                    }
                    Spacer()
                    if let id = manager.myUserID {
                        Text("Your ID: \(id.prefix(10))…").font(.system(size: 12)).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 22)
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Invite someone")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Generate a one-time code and send it to them privately. It works once and expires after 24 hours.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack {
                        Button("Generate invite code") { Task { await manager.createInvite() } }
                            .disabled(manager.isBusy)
                        if let code = manager.inviteCode {
                            Text(code)
                                .font(.system(size: 14, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var addFriendSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Add a friend")
            Card {
                HStack {
                    TextField("Paste their invite code", text: $redeemCode)
                        .themedField()
                        .onSubmit(sendRequest)
                    Button("Send request", action: sendRequest)
                        .disabled(redeemCode.trimmingCharacters(in: .whitespaces).isEmpty || manager.isBusy)
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var requestsSection: some View {
        if !manager.incoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Requests to you (\(manager.incoming.count))")
                Card {
                    ForEach(Array(manager.incoming.enumerated()), id: \.element.id) { index, friend in
                        if index > 0 { CardDivider() }
                        SettingRow(friend.displayName) {
                            HStack(spacing: 8) {
                                Button("Accept") { Task { await manager.accept(friend) } }
                                    .buttonStyle(.compactPill)
                                Button("Decline") { Task { await manager.decline(friend) } }
                                    .buttonStyle(.compactPill)
                                Button("Block", role: .destructive) { pendingBlock = friend }
                                    .buttonStyle(.compactPill)
                            }
                        }
                    }
                }
            }
        }
        if !manager.outgoing.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Waiting for them to accept")
                Card {
                    ForEach(Array(manager.outgoing.enumerated()), id: \.element.id) { index, friend in
                        if index > 0 { CardDivider() }
                        SettingRow(friend.displayName, titleColor: .secondary) {
                            Button("Cancel request") { Task { await manager.cancelRequest(friend) } }
                                .buttonStyle(.compactPill)
                        }
                    }
                }
            }
        }
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Your friends (\(manager.friends.count))")
            Card {
                if manager.friends.isEmpty {
                    SettingRow("No friends yet", subtitle: "Generate an invite code above and send it to someone.", titleColor: .secondary)
                }
                ForEach(Array(manager.friends.enumerated()), id: \.element.id) { index, friend in
                    if index > 0 { CardDivider() }
                    SettingRow(friend.displayName) {
                        Menu("Manage") {
                            Button("Remove friend", role: .destructive) { pendingRemoval = friend }
                            Button("Block…", role: .destructive) { pendingBlock = friend }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func sendRequest() {
        let code = redeemCode
        Task {
            if await manager.redeem(code: code) { redeemCode = "" }
        }
    }
}

/// "Share with friends" controls inside a group's settings sheet.
struct GroupSharingSection: View {
    @Bindable var group: GroupChatSession
    @Bindable private var friends = FriendsManager.shared

    @State private var members: [RelayFriend] = []
    @State private var error: String?
    @State private var isWorking = false
    @State private var confirmStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Friends").font(.system(size: 13)).foregroundStyle(.secondary)
            if !friends.isConnected {
                Text("Connect to a relay and add friends first (Friends, in the sidebar) to share this group.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else if !group.isShared {
                Text("Friends you add can read this chat and post in it. Your bots keep running only on your Mac. "
                    + "Only messages from now on are shared; earlier history stays private. Friends' messages are treated as "
                    + "untrusted: tools that need approval always ask you while a friend's message is in the conversation.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button("Share with friends") { Task { await share() } }.disabled(isWorking)
            } else {
                if !group.relayStatus.isEmpty {
                    Text(group.relayStatus).font(.system(size: 13)).foregroundStyle(Theme.warning)
                }
                if friends.friends.isEmpty {
                    Text("You have no friends yet — invite someone from Friends.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(friends.friends) { friend in
                    Toggle(isOn: Binding(
                        get: { members.contains { $0.userId == friend.userId } },
                        set: { on in Task { await setMember(friend, on) } }
                    )) {
                        Label(friend.displayName, systemImage: "person.crop.circle")
                    }
                    .disabled(isWorking)
                }
                Button("Stop sharing…", role: .destructive) { confirmStop = true }.disabled(isWorking)
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.warning) }
        }
        .task { await reloadMembers() }
        .confirmationDialog("Stop sharing “\(group.name)”?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { Task { await group.stopSharing(); members = [] } }
        } message: {
            Text("Friends lose access and the relay's copy of the chat is deleted. This group and its history stay on your Mac.")
        }
    }

    private func reloadMembers() async {
        guard let groupID = group.relayGroupID, let client = friends.client else { return }
        do { members = try await client.group(groupID).members } catch { self.error = FriendsManager.describe(error) }
    }

    private func share() async {
        isWorking = true; defer { isWorking = false }
        do { try await group.shareWithFriends(); error = nil; await reloadMembers() }
        catch { self.error = FriendsManager.describe(error) }
    }

    private func setMember(_ friend: RelayFriend, _ on: Bool) async {
        guard let groupID = group.relayGroupID, let client = friends.client else { return }
        isWorking = true; defer { isWorking = false }
        do {
            if on { try await client.addMember(friend.userId, to: groupID) }
            else { try await client.removeMember(friend.userId, from: groupID) }
            error = nil
        } catch { self.error = FriendsManager.describe(error) }
        await reloadMembers()
    }
}
