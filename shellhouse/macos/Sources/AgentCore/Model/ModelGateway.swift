import Foundation

/// Chat message in the shape the agent loop passes around.
public struct ChatMessage: Sendable, Codable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    /// Base64 PNGs, for vision-capable models. This is how a screenshot gets
    /// back to the model so the agent can see its own desktop instead of
    /// guessing coordinates.
    public var images: [String]?
    public var toolCalls: [ToolCall]?
    /// Set only on a `role == .tool` message built by
    /// `AgentRuntime.appendToolResult` — which tool produced it, so the UI
    /// can show "Ran <name>…" instead of a generic label. Never sent to
    /// the model itself (the wire-encoding types in each backend only
    /// read `role`/`content`/`images`).
    public var toolName: String?
    /// Set only on the `finish_task` summary message `AgentRuntime.loop`
    /// emits — marks it as a near-duplicate recap of whatever the model
    /// already said, so the UI can collapse it by default instead of
    /// showing the same result twice in a row.
    public var isTaskSummary: Bool = false

    public init(
        role: Role,
        content: String,
        images: [String]? = nil,
        toolCalls: [ToolCall]? = nil,
        toolName: String? = nil,
        isTaskSummary: Bool = false
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.isTaskSummary = isTaskSummary
    }
}

public struct ToolCall: Sendable, Codable {
    public let name: String
    public let arguments: [String: AnyCodable]

    public init(name: String, arguments: [String: AnyCodable]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct TokenUsage: Sendable, Codable {
    public let promptTokens: Int
    public let completionTokens: Int
    public var total: Int { promptTokens + completionTokens }
}

public struct ModelReply: Sendable {
    public let message: ChatMessage
    public let usage: TokenUsage?
}

/// The single chokepoint for model access.
///
/// Ported verbatim in spirit from the Python `ModelGateway`: the agent runtime
/// sees only this protocol, so swapping inference backends never touches the
/// loop. No implementation in this package makes a cloud call.
public protocol ModelBackend: Sendable {
    var name: String { get }
    /// Whether this backend's current model can accept images.
    func supportsVision(model: String?) async -> Bool
    func chat(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double
    ) async throws -> ModelReply
    /// Same call, but `onDelta` fires with each incremental chunk of the
    /// reply's text as it arrives, before the final `ModelReply` (still
    /// returned, still carrying the complete `content`/`toolCalls`/`usage`)
    /// comes back. This is what lets a chat bubble fill in live instead of
    /// the whole turn appearing at once after the full generation finishes
    /// — see `AgentRuntime.loop`'s `.messageDelta` event.
    ///
    /// Defaulted (below) to calling `chat` and firing `onDelta` once with
    /// the whole content, so a backend that can't stream (or hasn't been
    /// updated to) still works, just without the live-fill effect.
    func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModelReply
    func availableModels() async throws -> [String]
}

public extension ModelBackend {
    func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModelReply {
        let reply = try await chat(messages: messages, tools: tools, model: model, temperature: temperature)
        if !reply.message.content.isEmpty { onDelta(reply.message.content) }
        return reply
    }
}

/// Local inference via a native Ollama install.
///
/// Recommended starting backend: already Metal-accelerated, has real tool
/// calling, stable HTTP API. The cost is an external dependency the user must
/// install, which is awkward for a shipping app — see MLXBackend below for the
/// end state.
public actor OllamaBackend: ModelBackend {
    public let name = "ollama"

    private let baseURL: URL
    private let defaultModel: String
    private let session: URLSession
    private var visionCache: [String: Bool] = [:]
    /// Model names (lowercased) explicitly known to support vision, checked
    /// before falling back to `visionHints`. Model names are operator-chosen
    /// and don't follow any fixed convention (custom fine-tunes, quantized
    /// variants, etc.), so this exists rather than trying to widen the
    /// substring list to match every case — see `ContentView`'s "this model
    /// supports vision" toggle, which is what actually populates it.
    private let visionOverrides: Set<String>

    /// Substring hints for vision capability. Ollama's API does not advertise
    /// modality, so this is name matching — crude, and only a fallback for
    /// when the caller hasn't told us via `visionOverrides`.
    private let visionHints = [
        "vl", "vision", "llava", "bakllava", "moondream", "minicpm-v", "gemma3",
    ]

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        defaultModel: String = "qwen2.5:7b-instruct",
        timeout: TimeInterval = 600,
        visionOverrides: Set<String> = []
    ) {
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.visionOverrides = Set(visionOverrides.map { $0.lowercased() })
        let configuration = URLSessionConfiguration.ephemeral
        // Vision prompts and long contexts are slow on CPU; be generous.
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func supportsVision(model: String?) async -> Bool {
        let name = (model ?? defaultModel).lowercased()
        if let cached = visionCache[name] { return cached }
        let supported = visionOverrides.contains(name) || visionHints.contains { name.contains($0) }
        visionCache[name] = supported
        return supported
    }


    /// Fixed context window sent on every request. Ollama otherwise uses a
    /// small default, silently truncating long prompts and re-evaluating
    /// them; and changing this value between calls forces a model reload,
    /// so it must stay constant. Sized above `compactionThresholdTokens`
    /// (12k) plus room for the reply.
    public static let contextWindowTokens = 16_384

    static func requestOptions(temperature: Double) -> [String: AnyCodable] {
        ["temperature": AnyCodable(temperature), "num_ctx": AnyCodable(contextWindowTokens)]
    }

    public func chat(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double = 0.2
    ) async throws -> ModelReply {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OllamaChatRequest(
            model: model ?? defaultModel,
            messages: messages.map(OllamaMessage.init),
            tools: tools.isEmpty ? nil : tools.map(OllamaTool.init),
            stream: false,
            options: Self.requestOptions(temperature: temperature)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw ModelError.requestFailed(status: status, detail: detail)
        }

        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)

        // Ollama reports counts on the response body. Surfacing them is what
        // makes the task token budget enforceable at all.
        let usage = TokenUsage(
            promptTokens: decoded.prompt_eval_count ?? 0,
            completionTokens: decoded.eval_count ?? 0
        )

        return ModelReply(
            message: ChatMessage(
                role: .assistant,
                content: decoded.message?.content ?? "",
                toolCalls: decoded.message?.tool_calls?.map {
                    ToolCall(name: $0.function.name, arguments: $0.function.arguments)
                }
            ),
            usage: usage
        )
    }

    public func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModelReply {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OllamaChatRequest(
            model: model ?? defaultModel,
            messages: messages.map(OllamaMessage.init),
            tools: tools.isEmpty ? nil : tools.map(OllamaTool.init),
            stream: true,
            options: Self.requestOptions(temperature: temperature)
        )
        request.httpBody = try JSONEncoder().encode(body)

        // Ollama's streaming response is NDJSON: one JSON object per line,
        // each carrying the next slice of `message.content` plus `done`;
        // the very last line also carries the prompt/eval counts the
        // non-streaming path reads from the single response body.
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            var firstLine = ""
            for try await line in bytes.lines { firstLine = line; break }
            throw ModelError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: firstLine)
        }

        var content = ""
        var toolCalls: [ToolCall]?
        var promptTokens = 0
        var completionTokens = 0

        for try await line in bytes.lines {
            guard !line.isEmpty, let lineData = line.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: lineData) else { continue }
            if let delta = chunk.message?.content, !delta.isEmpty {
                content += delta
                onDelta(delta)
            }
            if let calls = chunk.message?.tool_calls, !calls.isEmpty {
                toolCalls = calls.map { ToolCall(name: $0.function.name, arguments: $0.function.arguments) }
            }
            promptTokens = chunk.prompt_eval_count ?? promptTokens
            completionTokens = chunk.eval_count ?? completionTokens
        }

        return ModelReply(
            message: ChatMessage(role: .assistant, content: content, toolCalls: toolCalls),
            usage: TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens)
        )
    }

    public func availableModels() async throws -> [String] {
        let (data, _) = try await session.data(
            from: baseURL.appendingPathComponent("api/tags")
        )
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        return try JSONDecoder().decode(TagsResponse.self, from: data).models.map(\.name)
    }

    // MARK: - Wire types

    private struct OllamaChatRequest: Encodable {
        let model: String
        let messages: [OllamaMessage]
        let tools: [OllamaTool]?
        let stream: Bool
        let options: [String: AnyCodable]
        /// `-1` = never unload this model due to inactivity, overriding
        /// Ollama's own default (unload after 5 idle minutes) — several
        /// bots idling between messages would otherwise fight the
        /// server into constantly reloading a model right when the next
        /// one actually needs it. This only covers "the app is running
        /// but idle"; explicitly unloading on quit is
        /// `OllamaManager.unloadAllModels()`, called from
        /// `AppDelegate.applicationShouldTerminate`.
        let keep_alive: Int = -1
    }

    private struct OllamaMessage: Codable {
        let role: String
        let content: String
        let images: [String]?

        init(_ message: ChatMessage) {
            self.role = message.role.rawValue
            self.content = message.content
            self.images = message.images
        }
    }

    private struct OllamaTool: Encodable {
        let type = "function"
        let function: Function

        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: AnyCodable
        }

        init(_ schema: ToolSchema) {
            self.function = Function(
                name: schema.name,
                description: schema.description,
                parameters: AnyCodable(schema.parameters)
            )
        }
    }

    private struct OllamaChatResponse: Decodable {
        struct Message: Decodable {
            struct ToolCallWrapper: Decodable {
                struct Function: Decodable {
                    let name: String
                    let arguments: [String: AnyCodable]
                }
                let function: Function
            }
            let content: String?
            let tool_calls: [ToolCallWrapper]?
        }
        let message: Message?
        let prompt_eval_count: Int?
        let eval_count: Int?
    }
}

/// In-process inference via MLX — the end state for a shipping app, because it
/// removes the external Ollama dependency entirely.
///
/// Left unimplemented on purpose rather than stubbed with something that
/// silently returns nothing. The hard part is not loading a model; it is tool
/// calling, which MLX does not give you as an API. You have to constrain
/// generation (grammar/JSON schema) or prompt for a structured block and parse
/// it, then handle the cases where a 7B model emits almost-valid JSON.
///
/// Do not cut over from Ollama until this passes the same eval suites.
public actor MLXBackend: ModelBackend {
    public let name = "mlx"

    public init() {}

    public func supportsVision(model: String?) async -> Bool { false }

    public func chat(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double
    ) async throws -> ModelReply {
        throw ModelError.notImplemented(
            """
            MLXBackend is not implemented yet. Use OllamaBackend. \
            See docs/MACOS-NATIVE.md, "Decision 2: model inference" — the open \
            problem is tool calling, not inference.
            """
        )
    }

    public func availableModels() async throws -> [String] { [] }
}

public enum ModelError: LocalizedError {
    case requestFailed(status: Int, detail: String)
    case notImplemented(String)
    case noBackend

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status, let detail):
            if status == -1 {
                return """
                Could not reach the model server. Is Ollama running? \
                Start it with `ollama serve`. (\(detail))
                """
            }
            return "Model request failed (\(status)): \(detail)"
        case .notImplemented(let message):
            return message
        case .noBackend:
            return "No model backend configured"
        }
    }
}

/// Minimal type-erased JSON value, so tool arguments and schemas can be passed
/// around without a concrete type per tool.
public struct AnyCodable: @unchecked Sendable, Codable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else { value = NSNull() }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map(AnyCodable.init))
        case let dict as [String: Any]: try container.encode(dict.mapValues(AnyCodable.init))
        default: try container.encodeNil()
        }
    }
}
