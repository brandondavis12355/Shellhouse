import Foundation

/// A backend that wraps another one (`ScheduledBackend`, `FallbackBackend`), so callers can see what actually
/// answers (local or remote changes how tokens are counted and how big the context is).
public protocol WrappingBackend {
    var wrapped: any ModelBackend { get }
}

extension ScheduledBackend: WrappingBackend {
    public var wrapped: any ModelBackend { inner }
}

public extension ModelBackend {
    /// The backend at the bottom of any wrappers.
    var innermost: any ModelBackend {
        var current: any ModelBackend = self
        while let wrapper = current as? WrappingBackend { current = wrapper.wrapped }
        return current
    }
}

/// Which of a bot's two models is in use, kept across its runs: once the main model has failed, the next runs go
/// straight to the fallback for a while instead of each waiting out the retries again.
public final class FallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var failedAt: Date?
    /// How long to stay on the fallback before trying the main model again.
    public let cooldown: TimeInterval

    public init(cooldown: TimeInterval = 5 * 60) { self.cooldown = cooldown }

    public func usingFallback(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let failedAt else { return false }
        if now.timeIntervalSince(failedAt) < cooldown { return true }
        self.failedAt = nil
        return false
    }

    private var switched = false
    func primaryFailed(now: Date = Date()) { lock.lock(); failedAt = now; switched = true; lock.unlock() }
    /// Whether this ends a stretch on the fallback.
    func primaryWorked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        failedAt = nil
        let was = switched
        switched = false
        return was
    }
}

/// The bot's main model, with a fallback for when it can't be reached: a few attempts on the main model, then the
/// same request to the fallback. An error the server answered with (a bad request, a refused key) isn't
/// "unreachable" and is passed on unchanged: the fallback wouldn't fix it, and it shouldn't hide it.
public struct FallbackBackend: ModelBackend, WrappingBackend {
    let primary: any ModelBackend
    let fallback: any ModelBackend
    let fallbackModel: String
    let state: FallbackState
    /// Tries on the main model before switching, and the waits between them.
    let retryDelays: [TimeInterval]
    /// Told when requests move to the fallback (true) or back to the main model (false).
    let onSwitch: @Sendable (_ toFallback: Bool, _ reason: String) -> Void

    public init(primary: any ModelBackend, fallback: any ModelBackend, fallbackModel: String, state: FallbackState,
                retryDelays: [TimeInterval] = [1, 3], onSwitch: @escaping @Sendable (Bool, String) -> Void = { _, _ in }) {
        self.primary = primary
        self.fallback = fallback
        self.fallbackModel = fallbackModel
        self.state = state
        self.retryDelays = retryDelays
        self.onSwitch = onSwitch
    }

    public var name: String { state.usingFallback() ? fallback.name : primary.name }
    public var wrapped: any ModelBackend { state.usingFallback() ? fallback : primary }

    public func supportsVision(model: String?) async -> Bool {
        state.usingFallback() ? await fallback.supportsVision(model: fallbackModel) : await primary.supportsVision(model: model)
    }

    public func availableModels() async throws -> [String] { try await primary.availableModels() }

    public func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
        try await route(model: model) { backend, model in
            try await backend.chat(messages: messages, tools: tools, model: model, temperature: temperature)
        }
    }

    public func chatStream(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double,
                           onDelta: @escaping @Sendable (String) -> Void) async throws -> ModelReply {
        try await route(model: model) { backend, model in
            try await backend.chatStream(messages: messages, tools: tools, model: model, temperature: temperature, onDelta: onDelta)
        }
    }

    private func route(model: String?, _ call: (any ModelBackend, String?) async throws -> ModelReply) async throws -> ModelReply {
        if state.usingFallback() { return try await call(fallback, fallbackModel) }
        var attempt = 0
        while true {
            do {
                let reply = try await call(primary, model)
                if state.primaryWorked() { onSwitch(false, "the main model answered again") }
                return reply
            } catch {
                guard Self.isUnreachable(error), !Task.isCancelled else { throw error }
                if attempt < retryDelays.count {
                    try? await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                    attempt += 1
                    continue
                }
                state.primaryFailed()
                onSwitch(true, Self.describe(error))
                return try await call(fallback, fallbackModel)
            }
        }
    }

    /// The main model couldn't answer at all: no connection, a timeout, the server down or overloaded, or rate-limited.
    public static func isUnreachable(_ error: Error) -> Bool {
        if ModelConnection.isConnectionProblem(error) { return true }
        if case ModelError.requestFailed(let status, _) = error { return status == -1 || status == 408 || status == 429 || status >= 500 }
        return false
    }

    static func describe(_ error: Error) -> String {
        if case ModelError.requestFailed(let status, _) = error, status > 0 { return "HTTP \(status)" }
        if (error as NSError).code == NSURLErrorTimedOut { return "no answer in time" }
        return ModelConnection.isConnectionProblem(error) ? "couldn't connect" : "no response"
    }
}
