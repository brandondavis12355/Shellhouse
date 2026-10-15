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
        var (data, response) = try await send(messages: messages, tools: tools, model: model, temperature: temperature,
                                              maxTokens: Self.replyTokenLimit)
        // A server that doesn't take `max_tokens` (or caps it lower): ask again with its own default.
        if (response as? HTTPURLResponse)?.statusCode == 400,
           (String(data: data, encoding: .utf8) ?? "").lowercased().contains("max_tokens") {
            (data, response) = try await send(messages: messages, tools: tools, model: model, temperature: temperature, maxTokens: nil)
        }
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
        temperature: Double,
        maxTokens: Int?
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let body = ChatRequest(
            model: model ?? defaultModel,
            messages: Self.wireMessages(messages),
            tools: tools.isEmpty ? nil : tools.map(Tool.init),
            temperature: temperature,
            max_tokens: maxTokens
        )
        request.httpBody = try ModelRequestEncoding.encode(body)
        return try await session.data(for: request)
    }

    public func availableModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        let isGemini = baseURL.host?.hasSuffix("generativelanguage.googleapis.com") == true
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
        let ids = try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id)
        // Gemini lists "models/gemini-…"; requests take the bare name.
        return isGemini ? ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } : ids
    }

    /// Google's OpenAI-compatible Gemini endpoint (https://ai.google.dev/gemini-api/docs/openai).
    public static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"

    private static func decodeReply(from data: Data) throws -> ModelReply {
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            return ModelReply(message: ChatMessage(role: .assistant, content: ""), usage: nil)
        }
        let toolCalls: [ToolCall]? = choice.message.tool_calls?.map { call in
            let argsData = call.function.arguments.data(using: .utf8) ?? Data()
            let args = (try? JSONDecoder().decode([String: AnyCodable].self, from: argsData)) ?? [:]
            return ToolCall(name: call.function.name, arguments: args, id: call.id)
        }
        let usage = decoded.usage.map { TokenUsage(promptTokens: $0.prompt_tokens, completionTokens: $0.completion_tokens) }
        return ModelReply(
            message: ChatMessage(role: .assistant, content: ReasoningText.strip(choice.message.content ?? ""), toolCalls: toolCalls),
            usage: usage
        )
    }

    // MARK: - Wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let tools: [Tool]?
        let temperature: Double
        let max_tokens: Int?
    }

    /// Room for a whole file in one `write_file` call. Left to the server, some providers stop a reply at a
    /// thousand or two tokens, cutting a tool call off mid-argument.
    static let replyTokenLimit = 8192

    /// Vision content uses OpenAI's multi-part `content` array
    /// (`text`/`image_url` parts) instead of a flat string whenever this
    /// message carries images; a plain text message still encodes as a
    /// plain string, which every OpenAI-compatible server accepts too.
    /// The conversation as OpenAI-style messages, with every tool call and its result paired by id, which strict
    /// servers (Gemini's OpenAI endpoint among them) require: an assistant turn carries its `tool_calls`, and each
    /// tool result names the call it answers in order. A call without an id gets one; a result whose call was
    /// summarized away becomes a plain note; a call that never got a result gets a placeholder one.
    static func wireMessages(_ messages: [ChatMessage]) -> [Message] {
        var out: [Message] = []
        var pending: [(id: String, name: String)] = []
        var counter = 0
        func flushPending() {
            for call in pending { out.append(Message(toolResult: "(no result was recorded for this call)", callID: call.id, name: call.name)) }
            pending = []
        }
        for message in messages {
            switch message.role {
            case .tool:
                if pending.isEmpty {
                    out.append(Message(role: "user", text: "[result of \(message.toolName ?? "a tool") from earlier]: \(message.content)"))
                } else {
                    let call = pending.removeFirst()
                    out.append(Message(toolResult: message.content, callID: call.id, name: message.toolName ?? call.name))
                }
            default:
                flushPending()
                let calls = (message.toolCalls ?? []).map { call -> (String, ToolCall) in
                    counter += 1
                    return (call.id ?? "call_\(counter)", call)
                }
                if message.role == .assistant, !calls.isEmpty {
                    out.append(Message(assistant: message.content, calls: calls))
                    pending = calls.map { ($0.0, $0.1.name) }
                } else {
                    out.append(Message(message))
                }
            }
        }
        flushPending()
        return out
    }

    struct Message: Encodable {
        let role: String
        let content: ContentValue?
        var tool_calls: [WireToolCall]? = nil
        var tool_call_id: String? = nil

        struct WireToolCall: Encodable {
            let id: String
            var type = "function"
            let function: Function
            struct Function: Encodable { let name: String; let arguments: String }
        }

        init(role: String, text: String) {
            self.role = role
            content = .text(text)
        }

        init(toolResult: String, callID: String, name: String) {
            role = "tool"
            content = .text(toolResult)
            tool_call_id = callID
        }

        init(assistant text: String, calls: [(String, ToolCall)]) {
            role = "assistant"
            content = text.isEmpty ? nil : .text(text)
            tool_calls = calls.map { id, call in
                let args = (try? JSONSerialization.data(withJSONObject: call.arguments.mapValues(\.value), options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return WireToolCall(id: id, function: .init(name: call.name, arguments: args))
            }
        }

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
                    let id: String?
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
