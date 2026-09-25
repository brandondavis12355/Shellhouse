import Foundation
import GRDB

/// Structured evidence (ADR-007), ported from the Python reference.
///
/// Retrieval that depends only on raw text chunks loses what makes findings
/// usable: where a claim came from, when, how confident it is, and what it
/// relates to. So findings are normalized before storage, separating the raw
/// source from the interpreted claim.
public struct Evidence: Sendable, Codable, Identifiable {
    public enum Source: String, Sendable, Codable {
        case browser, webSearch, fetchURL, shell, file, user, model
    }

    public enum RelationKind: String, Sendable, Codable {
        case supports, contradicts, refines, supersedes, relatesTo
    }

    public struct Relationship: Sendable, Codable {
        public let kind: RelationKind
        public let target: String

        public init(kind: RelationKind, target: String) {
            self.kind = kind
            self.target = target
        }
    }

    public let id: String
    public var taskID: String?
    /// The claim, in one sentence.
    public var finding: String
    /// What the claim is about.
    public var subject: String?
    public var source: Source
    /// 0...1. A search snippet is a lead (~0.5); a confirmed figure from an
    /// official page is a fact (~0.95).
    public var confidence: Double
    public var timestamp: Date
    /// Provenance: url, page, path.
    public var originalReference: [String: String]
    public var relationships: [Relationship]
    public var tags: [String]

    public init(
        id: String = "evidence_\(UUID().uuidString.prefix(12))",
        taskID: String? = nil,
        finding: String,
        subject: String? = nil,
        source: Source = .model,
        confidence: Double = 0.8,
        timestamp: Date = Date(),
        originalReference: [String: String] = [:],
        relationships: [Relationship] = [],
        tags: [String] = []
    ) {
        self.id = id
        self.taskID = taskID
        self.finding = finding
        self.subject = subject
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.timestamp = timestamp
        self.originalReference = originalReference
        self.relationships = relationships
        self.tags = tags
    }

    /// What actually gets embedded. Includes the subject so a query about a
    /// subject retrieves its findings, and excludes machinery (ids,
    /// timestamps) that would only add noise to the vector.
    public var embeddingText: String {
        var parts = [finding]
        if let subject { parts.append("Subject: \(subject)") }
        if !tags.isEmpty { parts.append("Tags: " + tags.joined(separator: ", ")) }
        if let reference = originalReference["url"] ?? originalReference["path"] {
            parts.append("Source: \(reference)")
        }
        return parts.joined(separator: "\n")
    }

    /// How this appears when injected into the model's context.
    public var contextLine: String {
        var line = subject.map { "[\($0)] " } ?? ""
        line += finding
        var meta = [String(format: "confidence %.2f", confidence)]
        meta.append(ISO8601DateFormatter().string(from: timestamp).prefix(10).description)
        if let reference = originalReference["url"] ?? originalReference["path"] {
            meta.append(reference)
        }
        return line + "  (" + meta.joined(separator: "; ") + ")"
    }

    // MARK: - Persistence glue

    var originalReferenceJSON: String {
        (try? String(data: JSONEncoder().encode(originalReference), encoding: .utf8)) ?? "{}"
    }

    var relationshipsJSON: String {
        (try? String(data: JSONEncoder().encode(relationships), encoding: .utf8)) ?? "[]"
    }

    var tagsJSON: String {
        (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
    }

    init?(row: Row) {
        guard let id: String = row["id"],
              let finding: String = row["finding"],
              let sourceRaw: String = row["source"],
              let timestamp: Date = row["timestamp"] else { return nil }

        func decode<T: Decodable>(_ column: String, default fallback: T) -> T {
            guard let json: String = row[column],
                  let data = json.data(using: .utf8),
                  let value = try? JSONDecoder().decode(T.self, from: data) else {
                return fallback
            }
            return value
        }

        self.init(
            id: id,
            taskID: row["taskID"],
            finding: finding,
            subject: row["subject"],
            source: Source(rawValue: sourceRaw) ?? .model,
            confidence: row["confidence"] ?? 0.8,
            timestamp: timestamp,
            originalReference: decode("originalReference", default: [:]),
            relationships: decode("relationships", default: []),
            tags: decode("tags", default: [])
        )
    }
}

/// Opportunistic evidence extraction from tool output.
///
/// This does NOT try to infer what a page "means" — turning text into claims
/// is the model's job, via the `save_evidence` tool. What it captures is the
/// provenance layer: that a specific URL was fetched at a specific time and
/// what it contained. That alone makes citation possible later, which is the
/// part agents most often get wrong.
public enum EvidenceExtractor {
    public static func fromToolResult(
        tool: String,
        arguments: [String: Any],
        result: [String: Any]
    ) -> [Evidence] {
        guard result["error"] == nil else { return [] }

        switch tool {
        case "fetch_url":
            guard let url = (result["url"] as? String) ?? (arguments["url"] as? String),
                  let text = result["text"] as? String, !text.isEmpty else { return [] }
            return [Evidence(
                finding: "Retrieved page content from \(url): \(text.prefix(600))",
                subject: url,
                source: .fetchURL,
                confidence: 0.6,   // raw retrieval, not an interpreted claim
                originalReference: ["url": url],
                tags: ["raw_retrieval"]
            )]

        case "web_search":
            guard let results = result["results"] as? [[String: Any]] else { return [] }
            return results.prefix(5).compactMap { item in
                guard let url = item["url"] as? String else { return nil }
                let title = item["title"] as? String ?? "Result"
                let snippet = item["snippet"] as? String ?? ""
                return Evidence(
                    finding: "\(title): \(snippet)",
                    subject: arguments["query"] as? String,
                    source: .webSearch,
                    confidence: 0.5,   // a snippet is a lead, not a fact
                    originalReference: ["url": url],
                    tags: ["search_result"]
                )
            }

        default:
            return []
        }
    }
}

/// Local embeddings. Same backend choice as the chat model: whatever the
/// ModelGateway is pointed at, with no cloud fallback.
public actor Embedder {
    private let baseURL: URL
    private let model: String
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = "nomic-embed-text"
    ) {
        self.baseURL = baseURL
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: configuration)
    }

    private struct BatchRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct BatchResponse: Decodable {
        let embeddings: [[Float]]?
    }

    private struct SingleRequest: Encodable {
        let model: String
        let prompt: String
    }

    private struct SingleResponse: Decodable {
        let embedding: [Float]
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        // Prefer the batch endpoint; fall back to one-per-text on older
        // Ollama builds that only have /api/embeddings.
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                BatchRequest(model: model, input: texts)
            )
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                throw EmbedderError.endpointMissing
            }
            if let embeddings = try JSONDecoder()
                .decode(BatchResponse.self, from: data).embeddings {
                return embeddings
            }
            throw EmbedderError.endpointMissing
        } catch {
            var out: [[Float]] = []
            for text in texts {
                var request = URLRequest(
                    url: baseURL.appendingPathComponent("api/embeddings")
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(
                    SingleRequest(model: model, prompt: text)
                )
                let (data, _) = try await session.data(for: request)
                out.append(
                    try JSONDecoder().decode(SingleResponse.self, from: data).embedding
                )
            }
            return out
        }
    }

    public func embedOne(_ text: String) async throws -> [Float]? {
        try await embed([text]).first
    }

    public enum EmbedderError: LocalizedError {
        case endpointMissing

        public var errorDescription: String? {
            switch self {
            case .endpointMissing:
                return """
                No embedding endpoint responded. Pull the model first:
                  ollama pull nomic-embed-text
                """
            }
        }
    }
}
