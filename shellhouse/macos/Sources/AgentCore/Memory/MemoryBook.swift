import Foundation

// A bot's long-term notes, managed instead of dumped. Ideas from the Generative Agents memory stream
// (retrieve by recency + importance + relevance) and from Letta/MemGPT-style consolidation (merge related
// notes, let stale low-value ones go to an archive), done deterministically: no model is asked what to
// remember or forget, and nothing is deleted outright (evicted entries are returned so they can be archived).

public struct MemoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var createdAt: Date
    /// Last time it was surfaced to the bot (injected into a prompt or returned by a search).
    public var lastUsedAt: Date?
    public var useCount: Int
    /// 1 (trivia) ... 5 (standing instruction or core fact).
    public var importance: Int
    /// Always part of the bot's core prompt; never evicted, merged away or archived.
    public var pinned: Bool
    /// Where it came from: "self" (remember tool), "user", "delegation", "goal", "import".
    public var source: String
    /// Semantic vector of `text` and the model that made it. Vectors from different models are never compared.
    public var embedding: [Float]?
    public var embeddingModel: String?

    public init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(), lastUsedAt: Date? = nil,
                useCount: Int = 0, importance: Int = 3, pinned: Bool = false, source: String = "self",
                embedding: [Float]? = nil, embeddingModel: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.importance = min(5, max(1, importance))
        self.pinned = pinned
        self.source = source
        self.embedding = embedding
        self.embeddingModel = embeddingModel
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, lastUsedAt, useCount, importance, pinned, source, embedding, embeddingModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        importance = min(5, max(1, try c.decodeIfPresent(Int.self, forKey: .importance) ?? 3))
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "self"
        // Stored as base64 Float32 bytes: a 1024-dimension vector is ~5.5 KB instead of ~20 KB of JSON numbers.
        if let data = try c.decodeIfPresent(Data.self, forKey: .embedding) {
            let vector = VectorMath.vector(from: data)
            embedding = vector.isEmpty ? nil : vector
        } else {
            embedding = nil
        }
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try c.encode(useCount, forKey: .useCount)
        try c.encode(importance, forKey: .importance)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(source, forKey: .source)
        if let embedding { try c.encode(VectorMath.data(from: embedding), forKey: .embedding) }
        try c.encodeIfPresent(embeddingModel, forKey: .embeddingModel)
    }
}

// MARK: - text handling

public enum MemoryText {
    static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "have", "has", "had", "are", "was", "were", "been", "will", "would", "could",
        "should", "you", "your", "our", "their", "they", "them", "what", "when", "where", "which", "who", "how", "why", "but", "not", "can",
        "does", "did", "its", "about", "into", "than", "then", "also", "just", "any", "all", "use", "uses", "using", "used", "get", "got",
    ]

    /// Lowercased words with a light stemmer (plural/-ing/-ed), stop words and 1-2 letter tokens removed.
    public static func terms(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "/" && $0 != "-" && $0 != "_" }
            .map { stem(String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".-/_"))) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    static func stem(_ word: String) -> String {
        guard word.count > 4, word.allSatisfy({ $0.isLetter }) else { return word }
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Jaccard overlap of the stemmed term sets, 0...1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(terms(a)), y = Set(terms(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}

// MARK: - the book

public struct MemoryBook: Codable, Equatable, Sendable {
    public private(set) var entries: [MemoryEntry]

    public static let capacity = 200
    public static let nearDuplicate = 0.7
    public static let mergeThreshold = 0.75
    /// Recency half-life in days: a note untouched for 3 weeks counts half as "recent".
    public static let halfLifeDays = 21.0
    /// Cosine similarity below `semanticFloor` is noise (unrelated text lands around 0.2-0.3 with the models
    /// in use); at `semanticCeiling` and above it is a clear match. Scores between are scaled 0...1.
    public static let semanticFloor = 0.30
    public static let semanticCeiling = 0.70
    /// Two notes this similar in meaning are the same fact, whatever the wording.
    public static let semanticDuplicate = 0.92

    public init(entries: [MemoryEntry] = []) { self.entries = entries }

    public init(legacy texts: [String], now: Date = Date()) {
        var book = MemoryBook()
        for text in texts { _ = book.add(text, source: "import", now: now) }
        self = book
    }

    public var texts: [String] { entries.map(\.text) }

    // MARK: adding

    public enum AddOutcome: Equatable, Sendable {
        case added(MemoryEntry)
        /// Rewrote an existing, very similar note instead of piling up a near-copy.
        case updated(MemoryEntry)
        case duplicate
        case rejected
    }

    @discardableResult
    public mutating func add(_ text: String, importance: Int? = nil, source: String = "self", pinned: Bool = false,
                             embedding: [Float]? = nil, embeddingModel: String? = nil, now: Date = Date()) -> AddOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }
        let rated = importance ?? Self.heuristicImportance(trimmed, source: source)
        if let index = entries.firstIndex(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            entries[index].lastUsedAt = now
            if pinned { entries[index].pinned = true }
            return .duplicate
        }
        func closeness(_ i: Int) -> Double {
            var best = MemoryText.similarity(entries[i].text, trimmed)
            if best < Self.nearDuplicate, let v = embedding, let other = entries[i].embedding, entries[i].embeddingModel == embeddingModel {
                let c = VectorMath.cosine(v, other)
                if c >= Self.semanticDuplicate { best = max(best, c) }
            }
            return best
        }
        if let index = entries.indices
            .map({ ($0, closeness($0)) })
            .filter({ $0.1 >= Self.nearDuplicate })
            .max(by: { $0.1 < $1.1 })?.0 {
            // Same fact, newer wording: keep one note, the newest text, the stronger importance.
            entries[index].text = trimmed
            entries[index].embedding = embedding           // the vector must describe the new wording
            entries[index].embeddingModel = embedding == nil ? nil : embeddingModel
            entries[index].importance = max(entries[index].importance, min(5, max(1, rated)))
            entries[index].lastUsedAt = now
            if pinned { entries[index].pinned = true }
            return .updated(entries[index])
        }
        let entry = MemoryEntry(text: trimmed, createdAt: now, importance: rated, pinned: pinned, source: source,
                                embedding: embedding, embeddingModel: embeddingModel)
        entries.append(entry)
        return .added(entry)
    }

    /// Notes over capacity, lowest keep-score first; pinned and high-importance notes go last. Returned so
    /// the caller can archive them. Call after `add`.
    public mutating func evictOverCapacity(now: Date = Date()) -> [MemoryEntry] {
        var evicted: [MemoryEntry] = []
        while entries.count > Self.capacity {
            guard let victim = entries.indices.filter({ !entries[$0].pinned })
                .min(by: { keepScore(entries[$0], now: now) < keepScore(entries[$1], now: now) }) else { break }
            evicted.append(entries.remove(at: victim))
        }
        return evicted
    }

    // MARK: embeddings

    /// Notes that have no vector from `model` yet (new, or made by a previously selected model).
    public func entriesNeedingEmbedding(model: String) -> [MemoryEntry] {
        entries.filter { $0.embedding == nil || $0.embeddingModel != model }
    }

    /// Attaches a vector only if the note's text is still what was embedded (it may have been rewritten meanwhile).
    public mutating func setEmbedding(id: String, forText text: String, vector: [Float], model: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].text == text else { return }
        entries[i].embedding = vector
        entries[i].embeddingModel = model
    }

    public var embeddedCount: Int { entries.filter { $0.embedding != nil }.count }

    public mutating func remove(ids: Set<String>) { entries.removeAll { ids.contains($0.id) } }
    public mutating func setPinned(_ id: String, _ pinned: Bool) { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].pinned = pinned } }
    public mutating func setImportance(_ id: String, _ value: Int) { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].importance = min(5, max(1, value)) } }

    // MARK: scoring

    public func recency(_ entry: MemoryEntry, now: Date) -> Double {
        let anchor = max(entry.createdAt, entry.lastUsedAt ?? entry.createdAt)
        let days = max(0, now.timeIntervalSince(anchor) / 86_400)
        return pow(0.5, days / Self.halfLifeDays)
    }

    /// How worth keeping a note is, independent of any query (used for eviction and for the core prompt).
    public func keepScore(_ entry: MemoryEntry, now: Date) -> Double {
        if entry.pinned { return 10 }
        let usage = min(1.0, Double(entry.useCount) / 5.0)
        return 0.5 * Double(entry.importance) / 5.0 + 0.3 * recency(entry, now: now) + 0.2 * usage
    }

    public struct Scored: Equatable, Sendable {
        public let entry: MemoryEntry
        public let score: Double
        public let relevance: Double
    }

    /// BM25-style relevance of every note to `query`, normalized to 0...1 by the best match.
    func relevance(to query: String) -> [String: Double] {
        let queryTerms = Set(MemoryText.terms(query))
        guard !queryTerms.isEmpty, !entries.isEmpty else { return [:] }
        let docs = entries.map { ($0.id, MemoryText.terms($0.text)) }
        let averageLength = max(1.0, Double(docs.map { $0.1.count }.reduce(0, +)) / Double(docs.count))
        var documentFrequency: [String: Int] = [:]
        for (_, terms) in docs { for t in Set(terms) where queryTerms.contains(t) { documentFrequency[t, default: 0] += 1 } }
        let n = Double(docs.count)
        let k1 = 1.4, b = 0.75
        var raw: [String: Double] = [:]
        for (id, terms) in docs {
            var counts: [String: Int] = [:]
            for t in terms where queryTerms.contains(t) { counts[t, default: 0] += 1 }
            guard !counts.isEmpty else { continue }
            var score = 0.0
            for (t, tf) in counts {
                let df = Double(documentFrequency[t] ?? 1)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let f = Double(tf)
                score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * Double(terms.count) / averageLength))
            }
            raw[id] = score
        }
        let best = raw.values.max() ?? 0
        guard best > 0 else { return [:] }
        return raw.mapValues { $0 / best }
    }

    /// Keyword relevance blended with meaning: for a note that has a vector from the same model as the query,
    /// 0.65 semantic + 0.35 keyword; otherwise keyword alone. The result is 0...1; below 0.12 counts as no match.
    func hybridRelevance(to query: String, queryEmbedding: [Float]?, queryModel: String?) -> [String: Double] {
        let lexical = relevance(to: query)
        guard let q = queryEmbedding, !q.isEmpty else { return lexical }
        var out = lexical
        for entry in entries {
            guard let v = entry.embedding, entry.embeddingModel == queryModel, v.count == q.count else { continue }
            let raw = VectorMath.cosine(q, v)
            let s = min(1, max(0, (raw - Self.semanticFloor) / (Self.semanticCeiling - Self.semanticFloor)))
            let lex = lexical[entry.id] ?? 0
            let blended = 0.65 * s + 0.35 * lex
            out[entry.id] = blended >= 0.12 ? blended : nil
        }
        return out
    }

    /// Notes relevant to `query`, best first: 0.5 relevance + 0.25 recency + 0.25 importance. Only notes with
    /// some relevance are returned (a query never drags in unrelated memories just because they are recent).
    public func rank(query: String, queryEmbedding: [Float]? = nil, queryModel: String? = nil, now: Date = Date(), limit: Int = 6) -> [Scored] {
        let rel = hybridRelevance(to: query, queryEmbedding: queryEmbedding, queryModel: queryModel)
        return entries.compactMap { entry -> Scored? in
            guard let r = rel[entry.id], r > 0 else { return nil }
            let score = 0.5 * r + 0.25 * recency(entry, now: now) + 0.25 * Double(entry.importance) / 5.0
            return Scored(entry: entry, score: score, relevance: r)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    /// The notes that go in the bot's system prompt every time: pinned first, then the highest keep-scores,
    /// skipping trivia. Everything else is found by `rank` when it is relevant.
    public func core(now: Date = Date(), limit: Int = 12) -> [MemoryEntry] {
        entries
            .filter { $0.pinned || $0.importance >= 2 }
            .sorted { keepScore($0, now: now) > keepScore($1, now: now) }
            .prefix(limit)
            .map { $0 }
    }

    public mutating func markUsed(_ ids: [String], now: Date = Date()) {
        let set = Set(ids)
        for i in entries.indices where set.contains(entries[i].id) {
            entries[i].lastUsedAt = now
            entries[i].useCount += 1
        }
    }

    // MARK: consolidation

    public struct Merge: Equatable, Sendable {
        public let kept: String
        public let removed: String
        public init(kept: String, removed: String) { self.kept = kept; self.removed = removed }
    }

    public struct Consolidation: Equatable, Sendable {
        public var merged: [Merge] = []
        public var archived: [MemoryEntry] = []
        public var isEmpty: Bool { merged.isEmpty && archived.isEmpty }
        public init(merged: [Merge] = [], archived: [MemoryEntry] = []) { self.merged = merged; self.archived = archived }
    }

    /// Housekeeping, run now and then: fold near-duplicate notes together and move stale, low-value, never-used
    /// notes to the archive. Pinned notes are untouched. Returns what changed so it can be shown or archived.
    public mutating func consolidate(now: Date = Date()) -> Consolidation {
        var report = Consolidation()

        // 1. merge near-duplicates (greedy, strongest pairs first)
        var changed = true
        while changed {
            changed = false
            var best: (i: Int, j: Int, sim: Double)?
            for i in entries.indices where !entries[i].pinned {
                for j in entries.indices where j > i && !entries[j].pinned {
                    var sim = MemoryText.similarity(entries[i].text, entries[j].text)
                    if sim < Self.mergeThreshold, let a = entries[i].embedding, let b = entries[j].embedding,
                       entries[i].embeddingModel == entries[j].embeddingModel {
                        let c = VectorMath.cosine(a, b)
                        if c >= Self.semanticDuplicate { sim = max(sim, c, Self.mergeThreshold) }
                    }
                    if sim >= Self.mergeThreshold, sim > (best?.sim ?? 0) { best = (i, j, sim) }
                }
            }
            if let pair = best {
                let a = entries[pair.i], b = entries[pair.j]
                // Keep the more important note; on a tie, the newer one.
                let keepA = a.importance != b.importance ? a.importance > b.importance : a.createdAt >= b.createdAt
                var keep = keepA ? a : b
                let drop = keepA ? b : a
                keep.importance = max(a.importance, b.importance)
                keep.useCount = a.useCount + b.useCount
                keep.lastUsedAt = [a.lastUsedAt, b.lastUsedAt].compactMap { $0 }.max()
                keep.createdAt = min(a.createdAt, b.createdAt)
                entries[keepA ? pair.i : pair.j] = keep
                entries.remove(at: keepA ? pair.j : pair.i)
                report.merged.append(Merge(kept: keep.text, removed: drop.text))
                changed = true
            }
        }

        // 2. archive stale, low-value, never-used notes
        let stale = entries.filter { entry in
            guard !entry.pinned, entry.useCount == 0 else { return false }
            let days = now.timeIntervalSince(max(entry.createdAt, entry.lastUsedAt ?? entry.createdAt)) / 86_400
            switch entry.importance {
            case ...2: return days > 45
            case 3: return days > 120
            default: return false
            }
        }
        if !stale.isEmpty {
            remove(ids: Set(stale.map(\.id)))
            report.archived = stale
        }
        return report
    }

    // MARK: importance

    private static let directives = ["always ", "never ", "must ", "do not ", "don't ", "dont ", "make sure", "important", "rule:", "remember to", "required", "only ", "no matter"]
    private static let identity = ["my name is", "call me", "i am ", "i'm ", "i prefer", "i like", "i hate", "i don't like", "we use ", "our ", "prefers ", "wants "]

    /// A first guess at how much a note matters, from its wording and where it came from. 1...5.
    public static func heuristicImportance(_ text: String, source: String) -> Int {
        let t = text.lowercased()
        var score = 3
        switch source {
        case "delegation": score = 2
        case "goal": score = 3
        case "user": score = 4
        default: break
        }
        if directives.contains(where: { t.contains($0) }) { score = max(score, 5) }
        else if identity.contains(where: { t.contains($0) }) { score = max(score, 4) }
        if t.count < 14 { score = min(score, 2) }
        if t.contains(where: \.isNumber) || t.contains("/") || t.contains("@") { score = min(5, score + 1) }
        return min(5, max(1, score))
    }
}
