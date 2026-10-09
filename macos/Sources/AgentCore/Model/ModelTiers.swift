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
