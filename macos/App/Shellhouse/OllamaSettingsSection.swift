import SwiftUI
import AppKit
import AgentCore

/// Runs `ollama`/`brew` one-shot commands for the settings UI below — a
/// simpler cousin of `OllamaManager`'s supervised `ollama serve`: these are
/// finite commands (install, pull) that report success/failure and exit,
/// not a long-lived process to keep alive.
enum OllamaCLI {
    static func binaryPath() -> String? {
        OllamaManager.Config().candidateBinaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func installViaHomebrew() async -> (success: Bool, output: String) {
        guard let brew = brewPath() else {
            return (false, "Homebrew not found — use the download link instead.")
        }
        return await run(binary: brew, arguments: ["install", "ollama"], timeout: 600)
    }

    /// Ollama's own documented one-liner. Piping a fetched script into `sh`
    /// is exactly the kind of thing to be wary of in general, but this is
    /// the install method ollama.com itself publishes — same trust level as
    /// running their downloaded installer by hand.
    static func installViaScript() async -> (success: Bool, output: String) {
        await run(binary: "/bin/sh", arguments: ["-c", "curl -fsSL https://ollama.com/install.sh | sh"], timeout: 600)
    }

    static func pull(_ model: String) async -> (success: Bool, output: String) {
        guard let ollama = binaryPath() else { return (false, "ollama not found") }
        // Large models take a while — generous but not unbounded, so a
        // stalled download doesn't hang the button forever.
        return await run(binary: ollama, arguments: ["pull", model], timeout: 1800)
    }

    private static func run(binary: String, arguments: [String], timeout: TimeInterval) async -> (success: Bool, output: String) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: binary)
            task.arguments = arguments
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            let lock = NSLock()
            var resumed = false
            func resume(_ success: Bool, _ output: String) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: (success, output))
            }

            task.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                resume(process.terminationStatus == 0, text)
            }

            do {
                try task.run()
            } catch {
                resume(false, error.localizedDescription)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if task.isRunning { task.terminate() }
                resume(false, "Timed out after \(Int(timeout))s")
            }
        }
    }

    /// The tail of a command's combined stdout/stderr — short enough to
    /// show as one line of status text instead of a wall of install/pull
    /// log output.
    static func lastLine(of output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? output
    }
}

/// "Is Ollama installed, what models does it have, and a way to install/
/// pull without leaving the app" — its own section in `AppSettingsView`
/// rather than something you have to know to do from a terminal first.
struct OllamaSettingsSection: View {
    @State private var binaryPath: String?
    @State private var models: [String] = []
    @State private var isRefreshing = false

    @State private var isInstalling = false
    @State private var installStatus: String?

    @State private var pullModelName = ""
    @State private var isPulling = false
    @State private var pullStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Ollama")
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }
                    .buttonStyle(.compactPill)
                    .disabled(isRefreshing)
                    .padding(.trailing, 4)
            }
            Card {
        VStack(alignment: .leading, spacing: 10) {

            if let binaryPath {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                    Text("Installed at \(binaryPath)").font(.system(size: 13)).foregroundStyle(.secondary)
                }

                Text(models.isEmpty ? "No models pulled yet." : "Installed models:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(models, id: \.self) { model in
                            Text(model).font(.system(size: 13, design: .monospaced))
                        }
                    }
                    .padding(.leading, 4)
                }

                HStack {
                    TextField("Model to pull, e.g. llama3.1:8b", text: $pullModelName)
                        .themedField()
                        .disabled(isPulling)
                        .onSubmit { Task { await pull() } }
                    Button(isPulling ? "Pulling…" : "Pull") { Task { await pull() } }
                        .disabled(pullModelName.trimmingCharacters(in: .whitespaces).isEmpty || isPulling)
                }
                if isPulling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Pulling — large models can take a while.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                if let pullStatus {
                    Text(pullStatus).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text("Ollama isn't installed — bots can't reach a model until it is.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(isInstalling ? "Installing…" : "Install (curl | sh)") {
                        Task { await install(using: OllamaCLI.installViaScript) }
                    }
                    .disabled(isInstalling)
                    .help("Ollama's own documented install command: curl -fsSL https://ollama.com/install.sh | sh")

                    if OllamaCLI.brewPath() != nil {
                        Button(isInstalling ? "Installing…" : "Install via Homebrew") {
                            Task { await install(using: OllamaCLI.installViaHomebrew) }
                        }
                        .disabled(isInstalling)
                    }

                    Button("Open ollama.com/download") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                    }
                }
                if isInstalling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Installing — this can take a minute.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                if let installStatus {
                    Text(installStatus).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(16)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        binaryPath = OllamaCLI.binaryPath()
        if binaryPath != nil {
            models = (try? await OllamaBackend().availableModels()) ?? []
        } else {
            models = []
        }
        isRefreshing = false
    }

    private func install(using method: () async -> (success: Bool, output: String)) async {
        isInstalling = true
        installStatus = nil
        let result = await method()
        isInstalling = false
        installStatus = result.success ? "Installed." : OllamaCLI.lastLine(of: result.output)
        guard result.success else { return }
        // `OllamaManager.start()` is idempotent and already checks for the
        // binary — calling it now (instead of waiting for a relaunch) is
        // what actually gets `ollama serve` running right after install.
        AppDelegate.shared?.ollama.start()
        await refresh()
    }

    private func pull() async {
        let name = pullModelName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isPulling = true
        pullStatus = nil
        let result = await OllamaCLI.pull(name)
        isPulling = false
        pullStatus = result.success ? "Pulled \(name)." : OllamaCLI.lastLine(of: result.output)
        guard result.success else { return }
        pullModelName = ""
        await refresh()
    }
}
