import Foundation

/// Any remote server speaking the OpenAI `/v1/chat/completions` +
/// `/v1/models` shape — vLLM, LM Studio, OpenRouter, Ollama's own OpenAI-
/// compat layer, self-hosted gateways, or OpenAI itself. `baseURL` should
/// include the `/v1` (or equivalent) prefix; this just appends
/// `chat/completions` and `models` to it.
///
/// Known gap: outgoing messages don't round-trip `tool_calls`/
/// `tool_call_id` (see `Message.init` below) — same simplification
/// `OllamaBackend` already makes, which Ollama's own server tolerates but
/// the strict OpenAI API technically does not always require pairing for.
/// Works against every OpenAI-compatible server this was tried against;
/// flagged here in case a stricter one ever rejects a tool-result turn.
public actor OpenAICompatibleBackend: ModelBackend {
    public let name = "openai-compatible"

    private let baseURL: URL
    private let apiKey: String
    private let defaultModel: String
    private let session: URLSession
    private let visionOverrides: Set<String>

    public init(
        baseURL: URL,
        apiKey: String,
        defaultModel: String,
        timeout: TimeInterval = 600,
        visionOverrides: Set<String> = []
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.visionOverrides = Set(visionOverrides.map { $0.lowercased() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    /// No modality-discovery API to rely on (`/v1/models` doesn't advertise
    /// it consistently across providers) — same manual-override shape as
    /// `OllamaBackend`, just with no substring-guessing fallback since
    /// remote model names are far less predictable ("gpt-4o" tells you
    /// nothing by pattern-matching the way "llava" does).
    public func supportsVision(model: String?) async -> Bool {
        visionOverrides.contains((model ?? defaultModel).lowercased())
    }

    public func chat(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double
    ) async throws -> ModelReply {
        let started = Date()
        let (data, response) = try await send(messages: messages, tools: tools, model: model, temperature: temperature)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Telemetry.recorder.modelCall(model: model ?? "remote", promptTokens: 0, completionTokens: 0,
                                         seconds: Date().timeIntervalSince(started), error: "HTTP \(status)")
            throw ModelError.requestFailed(status: status, detail: String(data: data, encoding: .utf8) ?? "")
        }
        let reply = try Self.decodeReply(from: data)
        Telemetry.recorder.modelCall(model: model ?? "remote", promptTokens: reply.usage?.promptTokens ?? 0,
                                     completionTokens: reply.usage?.completionTokens ?? 0, seconds: Date().timeIntervalSince(started))
        return reply
    }

    private func send(
        messages: [ChatMessage],
        tools: [ToolSchema],
        model: String?,
        temperature: Double
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let body = ChatRequest(
            model: model ?? defaultModel,
            messages: messages.map(Message.init),
            tools: tools.isEmpty ? nil : tools.map(Tool.init),
            temperature: temperature
        )
        request.httpBody = try ModelRequestEncoding.encode(body)
        return try await session.data(for: request)
    }

    public func availableModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModelError.requestFailed(status: status, detail: String(data: data, encoding: .utf8) ?? "")
        }
        struct ModelsResponse: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id)
    }

    private static func decodeReply(from data: Data) throws -> ModelReply {
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            return ModelReply(message: ChatMessage(role: .assistant, content: ""), usage: nil)
        }
        let toolCalls: [ToolCall]? = choice.message.tool_calls?.map { call in
            let argsData = call.function.arguments.data(using: .utf8) ?? Data()
            let args = (try? JSONDecoder().decode([String: AnyCodable].self, from: argsData)) ?? [:]
            return ToolCall(name: call.function.name, arguments: args)
        }
        let usage = decoded.usage.map { TokenUsage(promptTokens: $0.prompt_tokens, completionTokens: $0.completion_tokens) }
        return ModelReply(
            message: ChatMessage(role: .assistant, content: choice.message.content ?? "", toolCalls: toolCalls),
            usage: usage
        )
    }

    // MARK: - Wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let tools: [Tool]?
        let temperature: Double
    }

    /// Vision content uses OpenAI's multi-part `content` array
    /// (`text`/`image_url` parts) instead of a flat string whenever this
    /// message carries images; a plain text message still encodes as a
    /// plain string, which every OpenAI-compatible server accepts too.
    private struct Message: Encodable {
        let role: String
        let content: ContentValue

        enum ContentValue: Encodable {
            case text(String)
            case parts([Part])
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let string): try container.encode(string)
                case .parts(let parts): try container.encode(parts)
                }
            }
        }

        struct Part: Encodable {
            let type: String
            let text: String?
            let image_url: ImageURL?
            struct ImageURL: Encodable { let url: String }
        }

        init(_ message: ChatMessage) {
            role = message.role.rawValue
            if let images = message.images, !images.isEmpty {
                var parts: [Part] = []
                if !message.content.isEmpty {
                    parts.append(Part(type: "text", text: message.content, image_url: nil))
                }
                parts += images.map { Part(type: "image_url", text: nil, image_url: .init(url: "data:\($0.hasPrefix("/9j/") ? "image/jpeg" : "image/png");base64,\($0)")) }
                content = .parts(parts)
            } else {
                content = .text(message.content)
            }
        }
    }

    private struct Tool: Encodable {
        let type = "function"
        let function: Function
        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: AnyCodable
        }
        init(_ schema: ToolSchema) {
            function = Function(name: schema.name, description: schema.description, parameters: AnyCodable(schema.parameters))
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct ToolCallWrapper: Decodable {
                    struct Function: Decodable {
                        let name: String
                        /// A JSON-encoded string per the OpenAI spec (unlike
                        /// Ollama, which already hands back a decoded
                        /// object) — re-decoded in `decodeReply`.
                        let arguments: String
                    }
                    let function: Function
                }
                let content: String?
                let tool_calls: [ToolCallWrapper]?
            }
            let message: Message
        }
        struct Usage: Decodable {
            let prompt_tokens: Int
            let completion_tokens: Int
        }
        let choices: [Choice]
        let usage: Usage?
    }
}
