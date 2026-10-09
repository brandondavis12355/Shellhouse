import Foundation

/// What a bot needs from whatever is running its turns: the built-in Swift
/// loop (`AgentRuntime`) or the smolagents engine. Everything above this seam
/// (run lock, group turns, delegation, routines, the Debug Console) is
/// engine-agnostic.
public protocol AgentEngine: Actor {
    /// Restores prior conversation turns without calling the model.
    func seed(systemPrompt: String, history: [ChatMessage])
    /// Continue the conversation with a user message; returns when the turn is done.
    func send(_ userMessage: String, images: [String]) async
    func transcript() -> [ChatMessage]
    /// Whether untrusted content has entered this conversation, and from where.
    var isTainted: Bool { get async }
    var taintSources: [String] { get async }
    /// The user vouches that the conversation is trustworthy again.
    func clearTaint() async
}

extension AgentRuntime: AgentEngine {}

/// Which engine a bot uses. Persisted per bot; `builtin` is the default.
public enum AgentEngineKind: String, Codable, Sendable, CaseIterable {
    case builtin
    case smolagents

    public var label: String {
        switch self {
        case .builtin: return "Built-in"
        case .smolagents: return "smolagents (experimental)"
        }
    }
}
