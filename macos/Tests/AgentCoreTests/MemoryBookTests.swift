import XCTest
@testable import AgentCore

final class MemoryBookTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func book(_ texts: [String], at date: Date? = nil) -> MemoryBook {
        var b = MemoryBook()
        for t in texts { b.add(t, now: date ?? t0) }
        return b
    }

    // MARK: adding

    func testExactAndNearDuplicatesDoNotPileUp() {
        var b = MemoryBook()
        XCTAssertNotEqual(b.add("The user prefers concise answers with no preamble", now: t0), .rejected)
        XCTAssertEqual(b.add("the user prefers concise answers with no preamble", now: t0), .duplicate)
        if case .updated = b.add("User prefers concise answers, no preamble at all", now: t0.addingTimeInterval(day)) {} else { XCTFail("near-copy should update") }
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(b.entries[0].text, "User prefers concise answers, no preamble at all", "newest wording wins")
        XCTAssertEqual(b.add("   ", now: t0), .rejected)
    }

    func testUnrelatedNotesAreKeptSeparate() {
        let b = book(["Deploy goes through the staging server first", "Mr. Smith owns the daily stand-up", "The VM user is box with passwordless sudo"])
        XCTAssertEqual(b.entries.count, 3)
    }

    func testAnUpdateKeepsTheStrongerImportance() {
        var b = MemoryBook()
        b.add("Always run the linter before committing code changes", importance: 5, now: t0)
        b.add("Run the linter before committing code changes always", importance: 2, now: t0)
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(b.entries[0].importance, 5)
    }

    // MARK: importance heuristic

    func testImportanceReflectsWordingAndSource() {
        XCTAssertEqual(MemoryBook.heuristicImportance("Never push directly to main", source: "self"), 5)
        XCTAssertGreaterThanOrEqual(MemoryBook.heuristicImportance("The user prefers dark mode", source: "self"), 4)
        XCTAssertLessThanOrEqual(MemoryBook.heuristicImportance("Mr. Smith replied about the weather", source: "delegation"), 3)
        XCTAssertLessThanOrEqual(MemoryBook.heuristicImportance("ok", source: "self"), 2)
        XCTAssertGreaterThan(MemoryBook.heuristicImportance("Server lives at 192.0.2.10", source: "goal"),
                             MemoryBook.heuristicImportance("The server lives somewhere nearby okay", source: "goal"))
    }

    // MARK: ranking

    func testRelevanceDominatesAndUnrelatedNotesNeverAppear() {
        let b = book(["gh CLI version 2.46.0 is installed at /usr/bin/gh on this VM",
                      "The standup runs every day at nine in the morning",
                      "Cleo covers marketing and consumer experience"])
        let ranked = b.rank(query: "which version of the gh cli do we have installed?", now: t0)
        XCTAssertEqual(ranked.first?.entry.text.hasPrefix("gh CLI"), true)
        XCTAssertFalse(ranked.contains { $0.entry.text.contains("Cleo") }, "no overlap, no result, however recent")
        XCTAssertTrue(b.rank(query: "zebra quantum", now: t0).isEmpty)
        XCTAssertTrue(b.rank(query: "", now: t0).isEmpty)
    }

    func testRecencyAndImportanceBreakTiesBetweenEquallyRelevantNotes() {
        var b = MemoryBook()
        b.add("Deployment notes: staging uses the blue cluster", importance: 2, now: t0.addingTimeInterval(-120 * day))
        b.add("Deployment notes: production uses the green cluster", importance: 5, now: t0.addingTimeInterval(-1 * day))
        let ranked = b.rank(query: "deployment notes cluster", now: t0)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertTrue(ranked[0].entry.text.contains("production"), "recent and important first")
    }

    func testStemmingMatchesPluralsAndTenses() {
        let b = book(["The bot installs packages with apt-get"])
        XCTAssertFalse(b.rank(query: "installing a package", now: t0).isEmpty)
    }

    // MARK: core prompt notes, usage

    func testCorePutsPinnedFirstAndSkipsTriviaAndIsBounded() {
        var b = MemoryBook()
        let subjects = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa"]
        let verbs = ["restarts", "archives", "monitors", "balances", "compiles", "rotates", "indexes", "mirrors", "audits", "samples", "throttles", "replays", "validates", "schedules", "signs", "compresses"]
        for i in 0..<16 { b.add("\(subjects[i]) service \(verbs[(i * 7) % 16]) its own \(subjects[(i + 5) % 16]) dataset overnight", importance: 3, now: t0) }
        b.add("trivia", importance: 1, now: t0)
        b.add("Never reveal the deploy token to anyone in chat", importance: 5, pinned: true, now: t0.addingTimeInterval(-300 * day))
        let core = b.core(now: t0, limit: 12)
        XCTAssertEqual(core.count, 12)
        XCTAssertTrue(core[0].pinned)
        XCTAssertEqual(b.entries.count, 18, "16 distinct + trivia + pinned")
        XCTAssertFalse(core.contains { $0.text == "trivia" })
    }

    func testUsingANoteKeepsItFresh() {
        var b = MemoryBook()
        b.add("Staging database lives on the blue host", now: t0)
        let id = b.entries[0].id
        let later = t0.addingTimeInterval(60 * day)
        let before = b.recency(b.entries[0], now: later)
        b.markUsed([id], now: later)
        XCTAssertEqual(b.entries[0].useCount, 1)
        XCTAssertGreaterThan(b.recency(b.entries[0], now: later), before)
    }

    // MARK: eviction and consolidation

    func testOverCapacityEvictsTheLeastWorthKeepingAndNeverPinned() {
        var b = MemoryBook()
        b.add("Pinned core instruction that must survive forever", importance: 1, pinned: true, now: t0.addingTimeInterval(-900 * day))
        for i in 0..<MemoryBook.capacity + 5 {
            // distinct vocabulary per note so none collapse into each other
            b.add("zq\(i)a zq\(i)b zq\(i)c zq\(i)d zq\(i)e", importance: i % 5 + 1, now: t0.addingTimeInterval(-Double(i) * day))
        }
        let evicted = b.evictOverCapacity(now: t0)
        XCTAssertEqual(b.entries.count, MemoryBook.capacity)
        XCTAssertEqual(evicted.count, 6)
        XCTAssertTrue(b.entries.contains { $0.pinned })
        XCTAssertTrue(evicted.allSatisfy { $0.importance <= 2 }, "lowest value goes first: \(evicted.map(\.importance))")
    }

    func testConsolidationMergesNearDuplicatesKeepingTheBestOne() {
        var b = MemoryBook(entries: [
            MemoryEntry(text: "Staging deploys go out through the blue cluster every Friday afternoon", createdAt: t0.addingTimeInterval(-10 * day), importance: 3),
            MemoryEntry(text: "Staging deploys go out through the blue cluster every Friday afternoon now", createdAt: t0.addingTimeInterval(-1 * day), importance: 4),
            MemoryEntry(text: "Cleo handles marketing copy review", createdAt: t0, importance: 3),
        ])
        let report = b.consolidate(now: t0)
        XCTAssertEqual(b.entries.count, 2)
        XCTAssertEqual(report.merged.count, 1)
        XCTAssertEqual(b.entries.first { $0.text.contains("Staging") }?.importance, 4)
    }

    func testConsolidationArchivesStaleUnusedLowValueNotesOnly() {
        var b = MemoryBook(entries: [
            MemoryEntry(text: "Weather was cloudy during the old test run", createdAt: t0.addingTimeInterval(-100 * day), importance: 2),
            MemoryEntry(text: "Weather was cloudy but this note was used", createdAt: t0.addingTimeInterval(-100 * day), useCount: 3, importance: 2),
            MemoryEntry(text: "Old but important policy about release approvals", createdAt: t0.addingTimeInterval(-400 * day), importance: 5),
            MemoryEntry(text: "Pinned trivia stays", createdAt: t0.addingTimeInterval(-400 * day), importance: 1, pinned: true),
            MemoryEntry(text: "Medium note from last month about vendor onboarding", createdAt: t0.addingTimeInterval(-30 * day), importance: 3),
        ])
        let report = b.consolidate(now: t0)
        XCTAssertEqual(report.archived.map(\.text), ["Weather was cloudy during the old test run"])
        XCTAssertEqual(b.entries.count, 4)
    }

    func testConsolidatingACleanBookChangesNothing() {
        var b = book(["Alpha service restarts nightly", "Beta queue drains hourly", "Gamma cache warms on deploy"])
        XCTAssertTrue(b.consolidate(now: t0).isEmpty)
        XCTAssertEqual(b.entries.count, 3)
    }

    // MARK: persistence and migration

    func testLegacyStringListsMigrateAndRoundTrip() throws {
        let legacy = ["Always answer in English", "The VM user is box"]
        let b = MemoryBook(legacy: legacy, now: t0)
        XCTAssertEqual(b.texts, legacy)
        XCTAssertEqual(b.entries[0].source, "import")
        XCTAssertEqual(b.entries[0].importance, 5)
        let data = try JSONEncoder().encode(b)
        XCTAssertEqual(try JSONDecoder().decode(MemoryBook.self, from: data), b)
    }
}

// MARK: - semantic memory

final class SemanticMemoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let model = "test-embed"

    /// Tiny hand-made "meaning space": axis 0 = developer tooling, 1 = schedule, 2 = people.
    private func v(_ a: Float, _ b: Float, _ c: Float) -> [Float] { VectorMath.normalized([a, b, c]) }

    func testVectorMath() {
        XCTAssertEqual(VectorMath.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [1, 0, 0]), 0, "different sizes never compare")
        XCTAssertEqual(VectorMath.cosine([], []), 0)
        let round = VectorMath.vector(from: VectorMath.data(from: [0.25, -1.5, 3]))
        XCTAssertEqual(round, [0.25, -1.5, 3])
    }

    func testMeaningFindsANoteThatSharesNoWordsWithTheQuery() {
        var b = MemoryBook()
        b.add("gh is installed at /usr/bin/gh", embedding: v(1, 0, 0), embeddingModel: model, now: t0)
        b.add("The daily meeting happens at nine", embedding: v(0, 1, 0), embeddingModel: model, now: t0)
        // Query: "which github command line tool do we have?" has no keyword in common with either note.
        XCTAssertTrue(b.rank(query: "which github command line tool do we have", now: t0).isEmpty, "keyword-only finds nothing")
        let ranked = b.rank(query: "which github command line tool do we have", queryEmbedding: v(0.95, 0.1, 0), queryModel: model, now: t0)
        XCTAssertEqual(ranked.first?.entry.text, "gh is installed at /usr/bin/gh")
        XCTAssertFalse(ranked.contains { $0.entry.text.contains("meeting") }, "unrelated meaning stays out")
    }

    func testVectorsFromAnotherModelAreIgnoredSafely() {
        var b = MemoryBook()
        b.add("Cleo reviews copy", embedding: v(0, 0, 1), embeddingModel: "old-model", now: t0)
        let ranked = b.rank(query: "who reviews copy", queryEmbedding: v(0, 0, 1), queryModel: "new-model", now: t0)
        XCTAssertEqual(ranked.count, 1, "falls back to keywords for that note")
        XCTAssertEqual(b.entriesNeedingEmbedding(model: "new-model").count, 1)
        XCTAssertEqual(b.entriesNeedingEmbedding(model: "old-model").count, 0)
    }

    func testHybridBlendRewardsBothSignals() {
        var b = MemoryBook()
        b.add("Staging deploys use the blue cluster", embedding: v(1, 0, 0), embeddingModel: model, now: t0)
        b.add("Staging coffee machine is on the third floor", embedding: v(0, 0, 1), embeddingModel: model, now: t0)
        let ranked = b.rank(query: "staging deploys cluster", queryEmbedding: v(1, 0, 0), queryModel: model, now: t0)
        XCTAssertEqual(ranked.first?.entry.text, "Staging deploys use the blue cluster")
        if ranked.count > 1 { XCTAssertGreaterThan(ranked[0].score, ranked[1].score) }
    }

    func testTheSameFactInDifferentWordsIsRecognizedAsOne() {
        var b = MemoryBook()
        b.add("Deployments to production happen on Fridays", embedding: v(0.9, 0.4, 0), embeddingModel: model, now: t0)
        let outcome = b.add("We ship the live site at the end of every week", embedding: v(0.9, 0.41, 0), embeddingModel: model, now: t0)
        if case .updated = outcome {} else { XCTFail("semantic duplicate should update: \(outcome)") }
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(b.entries[0].text, "We ship the live site at the end of every week")
        XCTAssertEqual(b.entries[0].embedding?.count, 3, "vector replaced to match the new wording")
    }

    func testConsolidationMergesSemanticDuplicatesToo() {
        var b = MemoryBook(entries: [
            MemoryEntry(text: "Releases go out on Fridays", createdAt: t0, importance: 3, embedding: v(1, 0.2, 0), embeddingModel: model),
            MemoryEntry(text: "We deploy at the end of the week", createdAt: t0, importance: 4, embedding: v(1, 0.21, 0), embeddingModel: model),
            MemoryEntry(text: "Cleo handles marketing", createdAt: t0, importance: 3, embedding: v(0, 0, 1), embeddingModel: model),
        ])
        XCTAssertEqual(b.consolidate(now: t0).merged.count, 1)
        XCTAssertEqual(b.entries.count, 2)
    }

    func testRewrittenTextDoesNotKeepAStaleVectorFromAnEarlierEmbedRequest() {
        var b = MemoryBook()
        b.add("old wording about deploys", embedding: nil, now: t0)
        let id = b.entries[0].id
        b.setEmbedding(id: id, forText: "something else entirely", vector: v(1, 0, 0), model: model)
        XCTAssertNil(b.entries[0].embedding, "vector was computed for different text and is dropped")
        b.setEmbedding(id: id, forText: "old wording about deploys", vector: v(1, 0, 0), model: model)
        XCTAssertNotNil(b.entries[0].embedding)
        XCTAssertEqual(b.embeddedCount, 1)
    }

    func testVectorsSurviveSaveAndLoadCompactlyAndOldFilesStillLoad() throws {
        var b = MemoryBook()
        b.add("Note with a vector", embedding: VectorMath.normalized((0..<1024).map { Float($0 % 7) + 1 }), embeddingModel: model, now: t0)
        b.add("Note without one", now: t0)
        let data = try JSONEncoder().encode(b)
        XCTAssertLessThan(data.count, 9_000, "base64 floats, not a JSON number array: \(data.count) bytes")
        let back = try JSONDecoder().decode(MemoryBook.self, from: data)
        XCTAssertEqual(back, b)
        // A file written before embeddings existed has no embedding keys at all.
        let old = #"{"entries":[{"id":"1","text":"older note","createdAt":0,"useCount":2,"importance":4,"pinned":false,"source":"self"}]}"#
        let decoded = try JSONDecoder().decode(MemoryBook.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.entries[0].text, "older note")
        XCTAssertNil(decoded.entries[0].embedding)
    }
}

final class OllamaEmbedderTests: XCTestCase {
    func testRequestBodyAndPrefixesPerModelFamily() {
        let body = OllamaEmbedder.requestBody(model: "qwen3-embedding:8b", inputs: ["a"], dimensions: 1024, keepAlive: "5m")
        XCTAssertEqual(body["model"] as? String, "qwen3-embedding:8b")
        XCTAssertEqual(body["dimensions"] as? Int, 1024)
        XCTAssertEqual(body["keep_alive"] as? String, "5m")
        XCTAssertTrue(OllamaEmbedder.prefixed("hello", model: "qwen3-embedding:8b", isQuery: true).hasPrefix("Instruct:"))
        XCTAssertEqual(OllamaEmbedder.prefixed("hello", model: "qwen3-embedding:8b", isQuery: false), "hello", "documents get no instruction")
        XCTAssertEqual(OllamaEmbedder.prefixed("hello", model: "nomic-embed-text", isQuery: true), "search_query: hello")
        XCTAssertEqual(OllamaEmbedder.prefixed("hello", model: "nomic-embed-text", isQuery: false), "search_document: hello")
        XCTAssertEqual(OllamaEmbedder.prefixed(String(repeating: "x", count: 5_000), model: "other", isQuery: false).count, 2_000)
    }

    func testResponsesAreParsedAndNormalized() throws {
        let vectors = try OllamaEmbedder.parse(Data(#"{"embeddings":[[3,4],[0,2]]}"#.utf8))
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(VectorMath.norm(vectors[0]), 1, accuracy: 1e-5)
        XCTAssertThrowsError(try OllamaEmbedder.parse(Data(#"{"error":"nope"}"#.utf8)))
    }

    func testEmbeddingModelsAreRecognizedAndOrdered() {
        let installed = ["qwen3.5:4b", "nomic-embed-text:latest", "qwen3-embedding:8b", "gemma4:12b-mlx", "bge-m3:latest"]
        XCTAssertEqual(ModelTiers.embeddingModels(from: installed), ["qwen3-embedding:8b", "nomic-embed-text:latest", "bge-m3:latest"])
        XCTAssertTrue(ModelTiers.embeddingModels(from: ["qwen3.5:4b"]).isEmpty)
    }

    /// Live check against a real local Ollama: SHELLHOUSE_LIVE_EMBED=qwen3-embedding:8b swift test --filter OllamaEmbedderTests
    func testLiveEmbeddingsPutRelatedTextCloserThanUnrelatedText() async throws {
        guard let model = ProcessInfo.processInfo.environment["SHELLHOUSE_LIVE_EMBED"], !model.isEmpty else { throw XCTSkip("set SHELLHOUSE_LIVE_EMBED to an installed embedding model") }
        let embedder = OllamaEmbedder(model: model)
        let docs = try await embedder.embed(["gh CLI version 2.46.0 is installed at /usr/bin/gh", "The standup runs at nine every morning"], isQuery: false)
        let q = try await embedder.embed(["which github command line tool do we have?"], isQuery: true)
        XCTAssertEqual(docs[0].count, 1024)
        XCTAssertGreaterThan(VectorMath.cosine(q[0], docs[0]), VectorMath.cosine(q[0], docs[1]) + 0.2)
    }
}

final class LiveSemanticMemoryTests: XCTestCase {
    /// SHELLHOUSE_LIVE_EMBED=qwen3-embedding:8b swift test --filter LiveSemanticMemoryTests
    func testParaphrasedQuestionsFindTheRightNotesWithRealEmbeddings() async throws {
        guard let model = ProcessInfo.processInfo.environment["SHELLHOUSE_LIVE_EMBED"], !model.isEmpty else { throw XCTSkip("set SHELLHOUSE_LIVE_EMBED") }
        let embedder = OllamaEmbedder(model: model)
        let notes = [
            "gh 2.46.0 is installed at /usr/bin/gh on this VM",
            "The daily stand-up is posted at nine every morning",
            "Never push directly to the main branch; open a pull request",
            "Cleo reviews marketing copy and consumer experience",
            "The staging database lives on the blue host and is rebuilt every Friday",
            "The user prefers short answers without preamble",
        ]
        var book = MemoryBook()
        let vectors = try await embedder.embed(notes, isQuery: false)
        for (text, vector) in zip(notes, vectors) { book.add(text, importance: 3, embedding: vector, embeddingModel: model) }
        XCTAssertEqual(book.entries.count, 6, "distinct notes must not merge")

        let cases: [(query: String, expected: String)] = [
            ("which github command line tool do we have installed?", "gh 2.46.0"),
            ("when do the team status updates go out?", "stand-up"),
            ("can I commit straight to master?", "Never push"),
            ("who checks the ad text?", "Cleo"),
            ("where is the test database and when does it reset?", "staging database"),
            ("how verbose should my replies be?", "short answers"),
        ]
        var hits = 0
        for c in cases {
            let q = try await embedder.embed([c.query], isQuery: true)[0]
            let top = book.rank(query: c.query, queryEmbedding: q, queryModel: model, limit: 1).first?.entry.text ?? ""
            let keywordOnly = book.rank(query: c.query, limit: 1).first?.entry.text ?? ""
            print("LIVE \(top.contains(c.expected) ? "HIT " : "MISS") semantic[\(top.prefix(40))]  keyword[\(keywordOnly.prefix(40))]  <- \(c.query)")
            if top.contains(c.expected) { hits += 1 }
        }
        XCTAssertGreaterThanOrEqual(hits, 5, "semantic retrieval should answer at least 5 of 6 paraphrases")
        let off = try await embedder.embed(["what is the capital of France"], isQuery: true)[0]
        XCTAssertTrue(book.rank(query: "what is the capital of France", queryEmbedding: off, queryModel: model, limit: 3).isEmpty,
                      "an unrelated question must not drag notes in")
    }
}


final class OpenAIEmbedderTests: XCTestCase {
    func testParsesVectorsInIndexOrderAndNormalizes() throws {
        let json = #"{"data":[{"index":1,"embedding":[0,2]},{"index":0,"embedding":[3,4]}]}"#
        let vectors = try OpenAIEmbedder.parse(Data(json.utf8))
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0][0], 0.6, accuracy: 0.0001)   // index 0 first: [3,4] -> [0.6, 0.8]
        XCTAssertEqual(vectors[1][1], 1, accuracy: 0.0001)
        XCTAssertThrowsError(try OpenAIEmbedder.parse(Data(#"{"error":{"message":"bad key"}}"#.utf8)))
    }

    func testRequestBodyCarriesModelAndInputs() {
        let body = OpenAIEmbedder.requestBody(model: "text-embedding-3-small", inputs: ["a", "b"])
        XCTAssertEqual(body["model"] as? String, "text-embedding-3-small")
        XCTAssertEqual(body["input"] as? [String], ["a", "b"])
    }

    func testRemoteVectorsAreKeptApartFromLocalOnes() async {
        let defaults = UserDefaults.standard
        let keys = [ModelTiers.embeddingProviderKey, ModelTiers.embeddingRemoteBaseURLKey, ModelTiers.embeddingRemoteModelKey]
        let saved = keys.map { defaults.string(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set("remote", forKey: ModelTiers.embeddingProviderKey)
        defaults.set("https://example.invalid/v1", forKey: ModelTiers.embeddingRemoteBaseURLKey)
        defaults.set("embed-small", forKey: ModelTiers.embeddingRemoteModelKey)
        let identity = await ModelTiers.resolveEmbeddingModel()
        XCTAssertEqual(identity, "remote:embed-small")
        let embedder = await ModelTiers.embedder(for: identity ?? "")
        XCTAssertTrue(embedder is OpenAIEmbedder)
        defaults.set("http://example.invalid/v1", forKey: ModelTiers.embeddingRemoteBaseURLKey)   // plain http to a public name: not usable
        XCTAssertFalse(ModelTiers.embeddingUsesRemote)
    }

    func testPlainHttpIsAcceptedOnlyOnYourOwnNetworkAndBareOllamaGetsV1() {
        for ok in ["http://192.168.1.20:11434", "http://10.0.0.5:11434/v1", "http://172.20.1.1:8080/v1", "http://100.101.102.103:11434",
                   "http://studio.local:11434", "http://mac-studio:11434", "http://localhost:11434", "https://api.example.com/v1"] {
            XCTAssertNotNil(ModelTiers.usableBaseURL(ok), ok)
        }
        for bad in ["http://api.example.com/v1", "http://8.8.8.8:11434", "http://172.32.0.1:11434", "ftp://192.168.1.2", "not a url", ""] {
            XCTAssertNil(ModelTiers.usableBaseURL(bad), bad)
        }
        XCTAssertEqual(ModelTiers.usableBaseURL("http://192.168.1.20:11434")?.absoluteString, "http://192.168.1.20:11434/v1")
        XCTAssertEqual(ModelTiers.usableBaseURL("http://192.168.1.20:11434/")?.absoluteString, "http://192.168.1.20:11434/v1")
        XCTAssertEqual(ModelTiers.usableBaseURL("http://192.168.1.20:11434/v1")?.absoluteString, "http://192.168.1.20:11434/v1")
    }

    func testOllamaRootIsFoundOnlyForTheOllamaPort() {
        XCTAssertEqual(ModelTiers.ollamaRoot(URL(string: "http://10.0.0.5:11434/v1")!)?.absoluteString, "http://10.0.0.5:11434")
        XCTAssertEqual(ModelTiers.ollamaRoot(URL(string: "http://studio.local:11434")!)?.absoluteString, "http://studio.local:11434")
        XCTAssertNil(ModelTiers.ollamaRoot(URL(string: "http://10.0.0.5:1234/v1")!))
        XCTAssertNil(ModelTiers.ollamaRoot(URL(string: "https://api.openai.com/v1")!))
    }

    func testOllamaLikeServersAreRecognizedForReasoningOff() {
        XCTAssertTrue(ModelTiers.looksLikeOllama(URL(string: "http://10.0.0.5:11434/v1")!))
        XCTAssertTrue(ModelTiers.looksLikeOllama(URL(string: "http://studio.local:8080/v1")!))
        XCTAssertFalse(ModelTiers.looksLikeOllama(URL(string: "https://api.openai.com/v1")!))
    }

    func testReplaceRewritesOneNote() {
        var book = MemoryBook()
        guard case .added(let entry) = book.add("Prefers metric.") else { return XCTFail() }
        XCTAssertTrue(book.replace(id: entry.id, text: "Prefers imperial."))
        XCTAssertEqual(book.entries.count, 1)
        XCTAssertEqual(book.entries[0].text, "Prefers imperial.")
        XCTAssertFalse(book.replace(id: "missing", text: "nope"))
    }

    func testProceduresStayOutOfTheUserBlock() {
        var book = MemoryBook()
        book.add("Ask Tai Lung to run `systemctl restart nginx`.", source: "process")
        book.add("Name is Sam.", source: "user")
        book.add("Asked Tai: they answered the transcript.", source: "delegation")
        XCTAssertEqual(book.block(.user).map(\.text), ["Name is Sam."])
        XCTAssertEqual(book.block(.procedures).map(\.text), ["Ask Tai Lung to run `systemctl restart nginx`."])
    }

    func testNotesNeedReindexingWhenTheModelChanges() {
        var book = MemoryBook()
        _ = book.add("the gh tool is installed", embedding: [1, 0], embeddingModel: "qwen3-embedding:8b")
        XCTAssertTrue(book.entriesNeedingEmbedding(model: "qwen3-embedding:8b").isEmpty)
        XCTAssertEqual(book.entriesNeedingEmbedding(model: "remote:text-embedding-3-small").count, 1)
    }
}
