import Foundation
import Accelerate
import GRDB

/// Semantic memory without a vector database.
///
/// The Python build used Qdrant. That was the right call there and is the
/// wrong call here: Qdrant's HNSW index exists to make approximate search fast
/// across millions of vectors. A single user accumulates tens of thousands of
/// evidence rows, and at that scale an exact brute-force sweep with Accelerate
/// is sub-millisecond — faster than the network hop to Qdrant would have been,
/// with exact results instead of approximate ones, and one fewer service to
/// run.
///
/// Rough numbers for the tradeoff: 768-dimension vectors, cosine via
/// `cblas_sgemv` over a contiguous matrix. 50k rows is ~38M multiply-adds,
/// which Accelerate does in well under a millisecond on Apple Silicon. The
/// crossover where an index starts to pay is somewhere in the high hundreds of
/// thousands of rows; revisit then, not before.
///
/// Storage: vectors as BLOBs in SQLite, loaded into one contiguous `[Float]`
/// on first use and kept warm. Rebuilt on write.
public actor MemoryStore {
    private let dbPool: DatabasePool
    private let embedder: Embedder

    /// Warm cache: all vectors in one flat array for a single BLAS call.
    private var matrix: [Float] = []
    private var rowIDs: [Int64] = []
    private var dimension: Int = 0
    private var cacheValid = false

    // Reranking weights, matching the Python implementation so results can be
    // diffed against the reference build.
    private let weightSimilarity: Float = 1.0
    private let weightConfidence: Float = 0.3
    private let weightRecency: Float = 0.2
    private let recencyHalfLifeDays: Double = 30

    public init(dbPool: DatabasePool, embedder: Embedder) {
        self.dbPool = dbPool
        self.embedder = embedder
    }

    // MARK: - Schema

    public static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createMemory") { db in
            try db.create(table: "evidence") { t in
                t.column("id", .text).primaryKey()
                t.column("taskID", .text).indexed()
                t.column("finding", .text).notNull()
                t.column("subject", .text).indexed()
                t.column("source", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 0.8)
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("originalReference", .text)   // JSON
                t.column("relationships", .text)       // JSON
                t.column("tags", .text)                // JSON
                t.column("kind", .text).notNull().indexed()  // evidence|user|knowledge
                t.column("vector", .blob)
            }
            // Full-text search alongside vectors: keyword recall is often
            // better for exact identifiers (a version number, an error code)
            // where embeddings are weak.
            try db.create(virtualTable: "evidenceFTS", using: FTS5()) { t in
                t.synchronize(withTable: "evidence")
                t.column("finding")
                t.column("subject")
                t.tokenizer = .porter()
            }
        }
    }

    public enum Kind: String, Codable, Sendable {
        case evidence   // task findings
        case user       // durable preferences, explicitly allowed
        case knowledge  // documents
    }

    // MARK: - Write

    public func add(_ items: [Evidence], kind: Kind = .evidence) async throws -> Int {
        guard !items.isEmpty else { return 0 }

        let vectors = try await embedder.embed(items.map(\.embeddingText))
        guard vectors.count == items.count else {
            throw MemoryError.embeddingMismatch(expected: items.count, got: vectors.count)
        }

        try await dbPool.write { db in
            for (item, vector) in zip(items, vectors) {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO evidence
                      (id, taskID, finding, subject, source, confidence,
                       timestamp, originalReference, relationships, tags, kind, vector)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        item.id,
                        item.taskID,
                        item.finding,
                        item.subject,
                        item.source.rawValue,
                        item.confidence,
                        item.timestamp,
                        item.originalReferenceJSON,
                        item.relationshipsJSON,
                        item.tagsJSON,
                        kind.rawValue,
                        Self.encode(vector),
                    ]
                )
            }
        }
        cacheValid = false
        return items.count
    }

    // MARK: - Read

    public struct Hit: Sendable {
        public let evidence: Evidence
        public let similarity: Float
        public let rerankScore: Float
    }

    /// Hybrid retrieval: vector similarity, reranked on confidence and
    /// recency, with FTS results merged in.
    ///
    /// Recency decay matters more than it looks: a high-similarity snippet
    /// about last year's pricing is usually worse than a fresher, less similar
    /// one. Pass `applyRecency: false` for facts that don't decay.
    public func search(
        _ query: String,
        limit: Int = 6,
        kinds: Set<Kind> = [.evidence, .user, .knowledge],
        taskID: String? = nil,
        subject: String? = nil,
        minConfidence: Double = 0,
        applyRecency: Bool = true,
        includeKeywordSearch: Bool = true
    ) async throws -> [Hit] {
        guard let queryVector = try await embedder.embedOne(query) else { return [] }

        try await loadCacheIfNeeded()
        guard !rowIDs.isEmpty, dimension > 0 else { return [] }

        // One BLAS matrix-vector product gives every dot product at once.
        // Vectors are stored L2-normalized, so the dot product IS the cosine.
        var normalizedQuery = queryVector
        Self.normalize(&normalizedQuery)

        var scores = [Float](repeating: 0, count: rowIDs.count)
        cblas_sgemv(
            CblasRowMajor,
            CblasNoTrans,
            Int32(rowIDs.count),
            Int32(dimension),
            1.0,
            matrix,
            Int32(dimension),
            normalizedQuery,
            1,
            0.0,
            &scores,
            1
        )

        // Take a generous candidate set, then rerank. Reranking the top-6 of a
        // top-6 search accomplishes nothing.
        let candidateCount = min(rowIDs.count, max(limit * 8, 40))
        let topIndices = Self.topK(scores, k: candidateCount)
        let candidateIDs = topIndices.map { rowIDs[$0] }
        let similarityByID = Dictionary(
            uniqueKeysWithValues: topIndices.map { (rowIDs[$0], scores[$0]) }
        )

        var rows = try await fetchEvidence(
            ids: candidateIDs,
            kinds: kinds,
            taskID: taskID,
            subject: subject,
            minConfidence: minConfidence
        )

        if includeKeywordSearch {
            let keywordRows = try await keywordSearch(query, limit: limit, kinds: kinds)
            // Merge, preferring the vector hit's similarity when both matched.
            let existing = Set(rows.map(\.0.id))
            for row in keywordRows where !existing.contains(row.0.id) {
                rows.append(row)
            }
        }

        let now = Date()
        let hits = rows.map { (evidence, internalID) -> Hit in
            let similarity = similarityByID[internalID] ?? 0.3   // keyword-only hit
            let recency = applyRecency
                ? Self.recencyFactor(evidence.timestamp, now: now,
                                     halfLifeDays: recencyHalfLifeDays)
                : 1.0
            let score = weightSimilarity * similarity
                + weightConfidence * Float(evidence.confidence)
                + weightRecency * recency
            return Hit(evidence: evidence, similarity: similarity, rerankScore: score)
        }

        return hits
            .sorted { $0.rerankScore > $1.rerankScore }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Memory controls

    public func forget(id: String) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM evidence WHERE id = ?", arguments: [id])
        }
        cacheValid = false
    }

    public func forgetTask(_ taskID: String) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM evidence WHERE taskID = ?", arguments: [taskID])
        }
        cacheValid = false
    }

    public func stats() async throws -> [String: Int] {
        try await dbPool.read { db in
            var out: [String: Int] = [:]
            for kind in [Kind.evidence, .user, .knowledge] {
                out[kind.rawValue] = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM evidence WHERE kind = ?",
                    arguments: [kind.rawValue]
                ) ?? 0
            }
            return out
        }
    }

    // MARK: - Vector cache

    private func loadCacheIfNeeded() async throws {
        guard !cacheValid else { return }

        let loaded: [(Int64, [Float])] = try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT rowid, vector FROM evidence WHERE vector IS NOT NULL"
            ).compactMap { row in
                guard let blob: Data = row["vector"],
                      let rowid: Int64 = row["rowid"] else { return nil }
                return (rowid, Self.decode(blob))
            }
        }

        rowIDs = loaded.map(\.0)
        dimension = loaded.first?.1.count ?? 0
        matrix = []
        matrix.reserveCapacity(rowIDs.count * dimension)
        for (_, vector) in loaded {
            // Guard against a dimension change (e.g. someone swapped embedding
            // models) rather than producing silently garbage scores.
            guard vector.count == dimension else { continue }
            var normalized = vector
            Self.normalize(&normalized)
            matrix.append(contentsOf: normalized)
        }
        cacheValid = true
    }

    // MARK: - Helpers

    private func fetchEvidence(
        ids: [Int64],
        kinds: Set<Kind>,
        taskID: String?,
        subject: String?,
        minConfidence: Double
    ) async throws -> [(Evidence, Int64)] {
        guard !ids.isEmpty else { return [] }
        let kindList = kinds.map(\.rawValue)
        return try await dbPool.read { db in
            var sql = """
            SELECT *, rowid FROM evidence
            WHERE rowid IN (\(ids.map { _ in "?" }.joined(separator: ",")))
              AND kind IN (\(kindList.map { _ in "?" }.joined(separator: ",")))
              AND confidence >= ?
            """
            var arguments: [DatabaseValueConvertible] = ids + kindList + [minConfidence]
            if let taskID {
                sql += " AND taskID = ?"
                arguments.append(taskID)
            }
            if let subject {
                sql += " AND subject = ?"
                arguments.append(subject)
            }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .compactMap { row in
                    guard let evidence = Evidence(row: row),
                          let rowid: Int64 = row["rowid"] else { return nil }
                    return (evidence, rowid)
                }
        }
    }

    private func keywordSearch(
        _ query: String,
        limit: Int,
        kinds: Set<Kind>
    ) async throws -> [(Evidence, Int64)] {
        // FTS5 treats punctuation as syntax; strip it so a user's raw question
        // doesn't become a malformed MATCH expression.
        let sanitized = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .joined(separator: " OR ")
        guard !sanitized.isEmpty else { return [] }

        let kindList = kinds.map(\.rawValue)
        return try await dbPool.read { db in
            let sql = """
            SELECT evidence.*, evidence.rowid FROM evidence
            JOIN evidenceFTS ON evidenceFTS.rowid = evidence.rowid
            WHERE evidenceFTS MATCH ?
              AND evidence.kind IN (\(kindList.map { _ in "?" }.joined(separator: ",")))
            ORDER BY rank
            LIMIT ?
            """
            var arguments: [DatabaseValueConvertible] = [sanitized]
            arguments.append(contentsOf: kindList)
            arguments.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .compactMap { row in
                    guard let evidence = Evidence(row: row),
                          let rowid: Int64 = row["rowid"] else { return nil }
                    return (evidence, rowid)
                }
        }
    }

    private static func normalize(_ vector: inout [Float]) {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return }
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(vector.count))
    }

    private static func topK(_ scores: [Float], k: Int) -> [Int] {
        zip(scores.indices, scores)
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map(\.0)
    }

    private static func recencyFactor(
        _ timestamp: Date,
        now: Date,
        halfLifeDays: Double
    ) -> Float {
        let ageDays = max(0, now.timeIntervalSince(timestamp) / 86400)
        return Float(pow(0.5, ageDays / halfLifeDays))
    }

    private static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    public enum MemoryError: LocalizedError {
        case embeddingMismatch(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .embeddingMismatch(let expected, let got):
                return "Embedder returned \(got) vectors for \(expected) inputs"
            }
        }
    }
}
