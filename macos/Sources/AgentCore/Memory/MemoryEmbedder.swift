import Foundation

/// Turns text into vectors for semantic matching of memories ("which github command line tool do we have?" finds
/// the note about `gh`, which shares no words with it).
public protocol MemoryEmbedder: Sendable {
    var modelName: String { get }
    /// One vector per text, in order. `isQuery` marks a search query (some models want a different prefix).
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]]
}

public enum VectorMath {
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    public static func norm(_ a: [Float]) -> Float { dot(a, a).squareRoot() }

    /// Cosine similarity; 0 if either vector is empty/zero or the sizes differ (different models never compare).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let n = norm(a) * norm(b)
        return n > 0 ? Double(dot(a, b) / n) : 0
    }

    public static func normalized(_ a: [Float]) -> [Float] {
        let n = norm(a)
        return n > 0 ? a.map { $0 / n } : a
    }

    /// Compact storage: little-endian Float32 bytes.
    public static func data(from vector: [Float]) -> Data {
        var copy = vector
        return copy.withUnsafeMutableBytes { Data($0) }
    }

    public static func vector(from data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Ollama's `/api/embed`. Works with any installed embedding model (qwen3-embedding, nomic-embed-text, ...).
public struct OllamaEmbedder: MemoryEmbedder {
    public let baseURL: URL
    public let modelName: String
    /// Matryoshka-style models can return shorter vectors: 1024 is plenty for short notes and keeps storage small.
    public let dimensions: Int
    /// How long Ollama keeps the embedding model loaded after use (it can be several GB).
    public let keepAlive: String
    private let session: URLSession

    public init(model: String, baseURL: URL = URL(string: "http://127.0.0.1:11434")!, dimensions: Int = 1024, keepAlive: String = "5m", timeout: TimeInterval = 20) {
        self.modelName = model
        self.baseURL = baseURL
        self.dimensions = dimensions
        self.keepAlive = keepAlive
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    /// Model-specific text prefixes: qwen3-embedding wants an instruction on QUERIES only; nomic wants both.
    static func prefixed(_ text: String, model: String, isQuery: Bool) -> String {
        let m = model.lowercased()
        let clipped = String(text.prefix(2_000))
        if m.contains("qwen3-embedding") {
            return isQuery
                ? "Instruct: Given a chat message from a user or a teammate, retrieve the notes the assistant saved earlier that are relevant to it\nQuery: " + clipped
                : clipped
        }
        if m.contains("nomic-embed") { return (isQuery ? "search_query: " : "search_document: ") + clipped }
        if m.contains("e5") { return (isQuery ? "query: " : "passage: ") + clipped }
        return clipped
    }

    static func requestBody(model: String, inputs: [String], dimensions: Int, keepAlive: String) -> [String: Any] {
        ["model": model, "input": inputs, "dimensions": dimensions, "keep_alive": keepAlive, "truncate": true]
    }

    static func parse(_ data: Data) throws -> [[Float]] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["embeddings"] as? [[Double]] else { throw EmbedError.badResponse }
        return raw.map { VectorMath.normalized($0.map { Float($0) }) }
    }

    public enum EmbedError: Error, LocalizedError {
        case badResponse
        case http(Int, String)
        public var errorDescription: String? {
            switch self {
            case .badResponse: return "the embedding server returned an unexpected response"
            case .http(let code, let detail): return "embedding request failed (\(code)): \(detail.prefix(200))"
            }
        }
    }

    public func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let inputs = texts.map { Self.prefixed($0, model: modelName, isQuery: isQuery) }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(model: modelName, inputs: inputs, dimensions: dimensions, keepAlive: keepAlive))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EmbedError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let vectors = try Self.parse(data)
        guard vectors.count == texts.count else { throw EmbedError.badResponse }
        return vectors
    }
}


/// An OpenAI-compatible `/embeddings` endpoint (OpenAI itself, Gemini's compatibility layer, a self-hosted server).
/// Note the text of memories is sent to that endpoint.
public struct OpenAIEmbedder: MemoryEmbedder {
    public let baseURL: URL
    public let modelName: String
    private let apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, model: String, apiKey: String?, timeout: TimeInterval = 20) {
        self.baseURL = baseURL
        self.modelName = model
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    static func requestBody(model: String, inputs: [String]) -> [String: Any] {
        ["model": model, "input": inputs]
    }

    /// `{"data":[{"index":0,"embedding":[...]}, ...]}` in index order, each vector normalized.
    static func parse(_ data: Data) throws -> [[Float]] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { throw OllamaEmbedder.EmbedError.badResponse }
        let ordered = items.enumerated().sorted { (($0.element["index"] as? Int) ?? $0.offset) < (($1.element["index"] as? Int) ?? $1.offset) }
        return try ordered.map { entry in
            guard let raw = entry.element["embedding"] as? [Double] else { throw OllamaEmbedder.EmbedError.badResponse }
            return VectorMath.normalized(raw.map { Float($0) })
        }
    }

    public func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let inputs = texts.map { OllamaEmbedder.prefixed($0, model: modelName, isQuery: isQuery) }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(model: modelName, inputs: inputs))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaEmbedder.EmbedError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let vectors = try Self.parse(data)
        guard vectors.count == texts.count else { throw OllamaEmbedder.EmbedError.badResponse }
        return vectors
    }
}
