import AgentCore
import AppKit
import SwiftUI

/// "Linux host" address settings: the sandbox host's IP or hostname changes
/// with the network you're on, so it's editable here (and testable) instead of
/// being baked into the app.
struct HostSettingsSection: View {
    var onChanged: () -> Void = {}

    @State private var settings = HostSettingsStore.load()
    @State private var hostInput = ""
    @State private var userInput = ""
    @State private var result: (text: String, ok: Bool)?
    @State private var isWorking = false
    @State private var keyNote: String?

    private var enteredHost: String? { HostSettings.normalizedHost(from: hostInput) }
    private var enteredUser: String? { HostSettings.normalizedUser(from: userInput) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Linux host")
            Card {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where your sandbox host is on the network you're connected to. Use its IP address, or a name like "
                + "`linux-host.local` that keeps working when you change networks.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack {
                TextField("Address (IP or hostname)", text: $hostInput)
                    .themedField()
                    .onSubmit { Task { await saveAndReconnect() } }
                Menu("Recent") {
                    ForEach(settings.candidates, id: \.self) { candidate in
                        Button(candidate) { hostInput = candidate }
                    }
                }
                .fixedSize()
                .disabled(settings.candidates.isEmpty)
            }
            TextField("SSH user", text: $userInput).themedField()
            if !hostInput.isEmpty && enteredHost == nil {
                Text("That doesn't look like an IP address or hostname.").font(.system(size: 13)).foregroundStyle(Theme.warning)
            }
            HStack {
                Button("Test") { Task { await test() } }.disabled(enteredHost == nil || enteredUser == nil || isWorking)
                Button("Save & reconnect") { Task { await saveAndReconnect() } }
                    .disabled(enteredHost == nil || enteredUser == nil || isWorking)
                Button("Find on this network") { Task { await findHost() } }
                    .disabled(enteredUser == nil || isWorking)
                    .help("Tries your current address, recent addresses and \"<host name>.local\" until one answers.")
                if isWorking { ProgressView().controlSize(.small) }
            }
            if let result {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? Theme.positive : Theme.warning)
                    Text(result.text).font(.system(size: 13))
                }
            }
            Divider().padding(.vertical, 2)
            Text("The app connects with its own SSH key, kept inside the app, so it never needs to read your personal ~/.ssh keys. "
                + "If the connection says \"Permission denied\", authorize that key on the host once: copy the command below and paste "
                + "it into Terminal (it uses your normal SSH access).")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack {
                Button("Copy authorize command") { copyAuthorizeCommand() }
                    .disabled(enteredHost == nil || enteredUser == nil)
                if let keyNote { Text(keyNote).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
            }
        }
        .onAppear {
            hostInput = settings.host
            userInput = settings.user
        }
    }

    // MARK: Actions

    private func copyAuthorizeCommand() {
        guard let host = enteredHost, let user = enteredUser else { return }
        do {
            let key = try AppSSHIdentity.shared.ensureKey()
            guard let command = AppSSHIdentity.authorizeCommand(publicKey: key, user: user, host: host) else {
                keyNote = "Couldn't build the command for that host or user."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            keyNote = "Copied. Paste it into Terminal, then press Test."
        } catch {
            keyNote = error.localizedDescription
        }
    }

    private func test() async {
        guard let host = enteredHost, let user = enteredUser else { return }
        isWorking = true; defer { isWorking = false }
        let outcome = await Self.probe(host: host, user: user)
        result = outcome.ok
            ? ("Reached \(host) — it identifies as “\(outcome.detail)”.", true)
            : ("Couldn't reach \(host): \(outcome.detail)", false)
        if outcome.ok { settings.knownHostName = outcome.detail }
    }

    private func saveAndReconnect() async {
        guard let host = enteredHost, let user = enteredUser else { return }
        apply(host: host, user: user)
        result = ("Saved. Reconnecting the tunnel to \(host)…", true)
    }

    private func apply(host: String, user: String) {
        settings.user = user
        settings.use(host: host)
        hostInput = settings.host
        HostSettingsStore.save(settings)
        AppDelegate.shared?.tunnel.reconfigure(.init(
            host: settings.host, user: settings.user, managerSocketPath: settings.managerSocketPath,
            reverseForwards: SmolAgentsService.reverseForwards()
        ))
        onChanged()
    }

    /// Walks the candidate addresses and switches to the first that answers.
    private func findHost() async {
        guard let user = enteredUser else { return }
        isWorking = true; defer { isWorking = false }
        var candidates = settings.candidates
        if let typed = enteredHost, !candidates.contains(typed) { candidates.insert(typed, at: 0) }
        for candidate in candidates {
            result = ("Trying \(candidate)…", true)
            let outcome = await Self.probe(host: candidate, user: user)
            if outcome.ok {
                settings.knownHostName = outcome.detail
                apply(host: candidate, user: user)
                result = ("Found it at \(candidate) (“\(outcome.detail)”). Reconnecting the tunnel…", true)
                return
            }
        }
        result = ("Nothing answered on this network (\(candidates.joined(separator: ", "))). Check you're on the same network or VPN as the host, or enter its current address.", false)
    }

    /// `ssh user@host hostname` with a short timeout; never prompts.
    static func probe(host: String, user: String) async -> (ok: Bool, detail: String) {
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            _ = try? AppSSHIdentity.shared.ensureKey()
            task.arguments = AppSSHIdentity.shared.clientOptions() + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=accept-new",
                              "--", "\(user)@\(host)", "hostname"]
            let out = Pipe(), err = Pipe()
            task.standardOutput = out
            task.standardError = err
            do { try task.run() } catch { return (false, error.localizedDescription) }
            let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
            let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errors = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            task.waitUntilExit()
            killer.cancel()
            let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if task.terminationStatus == 0, !name.isEmpty { return (true, name) }
            let reason = errors.split(separator: "\n").last.map(String.init) ?? "no answer"
            return (false, reason)
        }.value
    }
}
