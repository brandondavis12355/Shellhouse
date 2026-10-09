import Foundation

/// Starts and supervises a local `ollama serve` for as long as this process
/// runs, the same way `SSHTunnel` supervises the SSH tunnel: idempotent
/// `start()` (reuses an already-running Ollama rather than erroring), restart
/// on unexpected exit, clean `stop()` on quit.
///
/// This exists so the app doesn't require the user to have run `ollama serve`
/// by hand in a terminal first — matching the "computer" side, which no
/// longer needs a manually-run tunnel either.
public final class OllamaManager: @unchecked Sendable {
    public struct Config: Sendable {
        public let port: Int
        /// Checked in order; the first one that exists is used. Homebrew
        /// installs here on both architectures, but GUI apps launched from
        /// Finder/Xcode often have a `PATH` that doesn't include either —
        /// unlike a Terminal shell, which is why this can't just rely on
        /// `env ollama serve`.
        public let candidateBinaryPaths: [String]
        /// `OLLAMA_NUM_PARALLEL` — how many requests Ollama will run at
        /// once against the SAME loaded model. Left unset, Ollama picks a
        /// default from available memory, which for anything but small
        /// models is often 1 — meaning every bot sharing one model would
        /// have its requests silently serialized at the Ollama server
        /// itself, no matter how independently `Bot`/`AgentRuntime` fire
        /// them. Forcing this is what actually lets several bots on the
        /// same model run concurrently rather than queueing behind each
        /// other one request at a time.
        public let numParallel: Int
        /// `OLLAMA_MAX_LOADED_MODELS` — how many distinct models can be
        /// loaded into memory at once. Bots on different models each need
        /// their own loaded copy; this caps that rather than leaving it to
        /// Ollama's own memory-based default, which can otherwise evict and
        /// reload models under memory pressure from several bots.
        public let maxLoadedModels: Int

        public init(
            port: Int = 11434,
            candidateBinaryPaths: [String] = [
                "/opt/homebrew/bin/ollama",
                "/usr/local/bin/ollama",
            ],
            numParallel: Int = 6,
            maxLoadedModels: Int = 3
        ) {
            self.port = port
            self.candidateBinaryPaths = candidateBinaryPaths
            self.numParallel = numParallel
            self.maxLoadedModels = maxLoadedModels
        }
    }

    private let config: Config
    private let onStderr: (String) -> Void
    private let restartDelay: UInt64 = 3_000_000_000  // 3s, in nanoseconds

    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var restartTask: Task<Void, Never>?

    public init(config: Config = .init(), onStderr: @escaping (String) -> Void = { _ in }) {
        self.config = config
        self.onStderr = onStderr
    }

    /// Idempotent, and reuses an already-running Ollama on `config.port`
    /// instead of spawning a second one (see `SSHTunnel.start` for why this
    /// check matters — Xcode's Stop button can leave a supervised child
    /// process running past the app that started it).
    public func start() {
        lock.lock()
        stopped = false
        let alreadyRunning = process != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        if isLocalPortOpen(port: config.port) {
            onStderr("Ollama is already listening on \(config.port) — reusing it instead of starting another.")
            return
        }

        guard let binary = config.candidateBinaryPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            onStderr(
                "Could not find the ollama binary in \(config.candidateBinaryPaths.joined(separator: ", ")). "
                + "Install it with `brew install ollama`, or start `ollama serve` yourself."
            )
            return
        }
        spawn(binary: binary)
    }

    public func stop() {
        lock.lock()
        stopped = true
        let current = process
        process = nil
        lock.unlock()
        restartTask?.cancel()
        current?.terminationHandler = nil
        current?.terminate()
    }

    /// Explicitly unloads every model Ollama currently has resident,
    /// regardless of `keep_alive` — call this right before quitting so
    /// models set to never idle-unload (see `OllamaChatRequest.keep_alive`)
    /// don't just stay loaded forever in the background, including when
    /// this manager didn't spawn `ollama serve` itself (a pre-existing,
    /// separately-running Ollama — see `start()`'s "reusing it" case —
    /// isn't touched by `stop()` at all, so this is the only place that
    /// actually frees its memory back).
    public func unloadAllModels() async {
        let baseURL = URL(string: "http://127.0.0.1:\(config.port)")!
        struct PSResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        guard let (data, _) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("api/ps")),
              let running = try? JSONDecoder().decode(PSResponse.self, from: data)
        else { return }

        struct UnloadRequest: Encodable {
            let model: String
            let prompt = ""
            let keep_alive = 0
        }
        for model in running.models {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(UnloadRequest(model: model.name))
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func spawn(binary: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["serve"]
        // `task.environment = nil` (the default) would already inherit the
        // parent's environment, but we need to ADD to it, not replace it —
        // dropping the inherited `PATH`/`HOME`/etc. by only setting these
        // two keys would break `ollama serve` itself.
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_NUM_PARALLEL"] = String(config.numParallel)
        environment["OLLAMA_MAX_LOADED_MODELS"] = String(config.maxLoadedModels)
        task.environment = environment

        let errPipe = Pipe()
        task.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [onStderr] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onStderr(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        task.terminationHandler = { [weak self] _ in
            self?.handleExit(binary: binary)
        }

        do {
            try task.run()
            lock.lock()
            process = task
            lock.unlock()
        } catch {
            onStderr("Failed to launch ollama serve: \(error.localizedDescription)")
            scheduleRestart(binary: binary)
        }
    }

    private func handleExit(binary: String) {
        lock.lock()
        process = nil
        let shouldRestart = !stopped
        lock.unlock()
        if shouldRestart { scheduleRestart(binary: binary) }
    }

    /// See `SSHTunnel.isStillWantedAfterRestartDelay` for why this locked
    /// check is a plain synchronous method rather than inlined in the
    /// `Task` body: `NSLock.lock()/unlock()` are unavailable from async
    /// contexts under the Swift 6 language mode.
    private func isStillWantedAfterRestartDelay() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    private func scheduleRestart(binary: String) {
        restartTask = Task { [weak self, restartDelay] in
            try? await Task.sleep(nanoseconds: restartDelay)
            guard let self, !Task.isCancelled else { return }
            if self.isStillWantedAfterRestartDelay() { self.spawn(binary: binary) }
        }
    }
}
