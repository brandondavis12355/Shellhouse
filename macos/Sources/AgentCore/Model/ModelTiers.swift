import Foundation

/// Two-tier model routing: the bot's own model does the real work; a small, fast model handles
/// the cheap decisions around it (reply gate, goal-intake check, small talk, parallel helpers).
/// Empty `fastModel` means "no fast tier": everything uses the bot's own model.
public enum ModelTiers {
    public static let fastModelKey = "fastModel"
    public static let helperLimit = 4

    public static var fastModel: String {
        get { UserDefaults.standard.string(forKey: fastModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: fastModelKey) }
    }

    // MARK: Remote fast model (an OpenAI-compatible endpoint instead of Ollama)

    public static let fastProviderKey = "fastModel.provider"          // "ollama" (default) or "remote"
    public static let fastRemoteBaseURLKey = "fastModel.remoteBaseURL"
    public static let fastRemoteModelKey = "fastModel.remoteModel"
    /// Keychain entry for the remote fast model's API key (never in UserDefaults).
    public static let fastRemoteAPIKeySecretName = "FAST_MODEL_API_KEY"

    public static var fastRemoteBaseURL: URL? {
        usableBaseURL(UserDefaults.standard.string(forKey: fastRemoteBaseURLKey) ?? "")
    }

    /// Hosts where plain http is acceptable because the traffic stays on this Mac or your own network: loopback,
    /// private ranges (10/8, 172.16/12, 192.168/16), link-local, Tailscale-style 100.64/10, and local names
    /// (`.local`, `.lan`, or a bare hostname). Anything else must be https.
    static func isPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".localhost") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            switch (parts[0], parts[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        return !host.contains(".") && !host.contains(":")   // a bare hostname: only resolvable on a local network
    }

    public static var fastRemoteModel: String {
        (UserDefaults.standard.string(forKey: fastRemoteModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The fast tier runs on a remote endpoint: chosen, with a usable https URL and a model.
    public static var fastUsesRemote: Bool {
        UserDefaults.standard.string(forKey: fastProviderKey) == "remote" && fastRemoteBaseURL != nil && !fastRemoteModel.isEmpty
    }

    /// Which model a cheap call uses, for logs.
    public static func fastModelLabel(main: String) -> String {
        fastUsesRemote ? "remote \(fastRemoteModel)" : cheapModel(main: main)
    }

    /// The model for a cheap call: the fast tier if set, else the bot's own.
    public static func cheapModel(main: String) -> String {
        let fast = fastModel
        return fast.isEmpty ? main : fast
    }

    /// Smallest installed model that looks like a general chat model, for a one-click default.
    public static func suggestedFastModel(from installed: [String]) -> String? {
        let skip = ["coder", "base", "embed", "vl", "vision"]
        func size(_ name: String) -> Double {
            // "qwen3.5:4b" -> 4 ; "gemma4:12b-mlx" -> 12 ; "...a3b" ignored
            guard let tag = name.split(separator: ":").last else { return .infinity }
            let digits = tag.prefix { $0.isNumber || $0 == "." }
            return Double(digits) ?? .infinity
        }
        return installed
            .filter { name in !skip.contains { name.lowercased().contains($0) } && size(name) <= 8 }
            .min { size($0) < size($1) }
    }

    // MARK: embedding model (semantic memory)

    public static let embeddingModelKey = "embeddingModel"

    // MARK: Remote embeddings (an OpenAI-compatible /embeddings endpoint instead of Ollama)

    public static let embeddingProviderKey = "embedding.provider"          // "ollama" (default) or "remote"
    public static let embeddingRemoteBaseURLKey = "embedding.remoteBaseURL"
    public static let embeddingRemoteModelKey = "embedding.remoteModel"
    /// Keychain entry for the remote embedding endpoint's API key (never in UserDefaults).
    public static let embeddingAPIKeySecretName = "EMBEDDING_API_KEY"
    /// Prefix on the model name stored with each memory vector when the vectors come from the remote endpoint, so
    /// they are never compared with local vectors that happen to share a model name.
    static let remoteIdentityPrefix = "remote:"

    /// https only (plain http just for this Mac), same rule as the remote fast model.
    static func usableBaseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else { return nil }
        guard url.scheme == "https" || (url.scheme == "http" && isPrivateHost(host)) else { return nil }
        // A bare Ollama address (`http://host:11434`): its OpenAI-compatible API lives under /v1.
        if url.port == 11434, url.path.isEmpty || url.path == "/",
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.path = "/v1"
            return parts.url ?? url
        }
        return url
    }

    /// Posted when the embedding model or where it runs changes, so every bot re-indexes its notes for the new model.
    public static let embeddingChangedNotification = Notification.Name("shellhouse.embeddingSettingsChanged")
    public static func embeddingSettingsChanged() {
        NotificationCenter.default.post(name: embeddingChangedNotification, object: nil)
    }

    public static var embeddingRemoteBaseURL: URL? {
        usableBaseURL(UserDefaults.standard.string(forKey: embeddingRemoteBaseURLKey) ?? "")
    }

    public static var embeddingRemoteModel: String {
        (UserDefaults.standard.string(forKey: embeddingRemoteModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Memory search runs on a remote endpoint: chosen, with a usable URL and a model id.
    public static var embeddingUsesRemote: Bool {
        UserDefaults.standard.string(forKey: embeddingProviderKey) == "remote" && embeddingRemoteBaseURL != nil && !embeddingRemoteModel.isEmpty
    }

    /// The embedder for a model name returned by `resolveEmbeddingModel()`: the remote endpoint (with its Keychain
    /// key) for a remote identity, Ollama otherwise.
    public static func embedder(for model: String, timeout: TimeInterval = 20) async -> MemoryEmbedder? {
        if model.hasPrefix(remoteIdentityPrefix) {
            guard let base = embeddingRemoteBaseURL else { return nil }
            let key = (try? await SecretStore().resolveOne(name: embeddingAPIKeySecretName)) ?? nil
            return OpenAIEmbedder(baseURL: base, model: String(model.dropFirst(remoteIdentityPrefix.count)), apiKey: key, timeout: timeout)
        }
        return OllamaEmbedder(model: model, timeout: timeout)
    }

    /// Empty means "not chosen yet": the first use auto-selects an installed embedding model, if there is one.
    public static var embeddingModel: String {
        get { UserDefaults.standard.string(forKey: embeddingModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: embeddingModelKey) }
    }

    /// Installed models that are embedding models (by name), best-known first.
    public static func embeddingModels(from installed: [String]) -> [String] {
        let preferred = ["qwen3-embedding", "nomic-embed", "bge-", "mxbai-embed", "snowflake-arctic-embed", "all-minilm"]
        let found = installed.filter { name in let n = name.lowercased(); return n.contains("embed") || n.contains("bge-") || n.contains("minilm") }
        return found.sorted { a, b in
            let ra = preferred.firstIndex { a.lowercased().contains($0) } ?? preferred.count
            let rb = preferred.firstIndex { b.lowercased().contains($0) } ?? preferred.count
            return ra == rb ? a < b : ra < rb
        }
    }

    private static let resolveLock = NSLock()
    nonisolated(unsafe) private static var triedAutoSelect = false

    /// The embedding model to use right now, or nil if none is configured or installed. The first call with
    /// nothing configured looks at what Ollama has installed and remembers a good match (visible in Settings).
    public static func resolveEmbeddingModel() async -> String? {
        if embeddingUsesRemote { return remoteIdentityPrefix + embeddingRemoteModel }
        let configured = embeddingModel
        if !configured.isEmpty { return configured }
        resolveLock.lock()
        let already = triedAutoSelect
        triedAutoSelect = true
        resolveLock.unlock()
        guard !already else { return nil }
        guard let installed = try? await OllamaBackend().availableModels(), let pick = embeddingModels(from: installed).first else { return nil }
        embeddingModel = pick
        return pick
    }

    private static let autoConfiguredKey = "modelTiersAutoConfigured"

    /// First launch with these features present: turn them on. Picks the smallest installed chat model as the fast
    /// tier and an installed embedding model for memory search. Never overrides a choice the user already made, and
    /// runs once, so choosing "None" in Settings sticks.
    public static func autoConfigure() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoConfiguredKey) else { return }
        guard let installed = try? await OllamaBackend().availableModels(), !installed.isEmpty else { return }   // retry next launch
        defaults.set(true, forKey: autoConfiguredKey)
        if fastModel.isEmpty, let pick = suggestedFastModel(from: installed) { fastModel = pick }
        if embeddingModel.isEmpty, let pick = embeddingModels(from: installed).first { embeddingModel = pick }
    }
}
