import Foundation

/// How far a saved note may be believed. Decided when it is written, from where it came from and whether the run that
/// wrote it had read untrusted content (`ToolGate` taint). Order matters: a rewrite can only keep or lower a note's
/// class. Policy owner: security (docs/HARNESS-REDESIGN.md 3.4a).
///
/// - `user`: typed or approved by the user in the app. May be pinned into the system prompt.
/// - `harness`: written by the app itself (a learned procedure, a group goal). May be in the system prompt.
/// - `selfNote`: the bot's own `remember` call in a run with no untrusted content. May be in the system prompt.
/// - `untrusted`: from a delegation, an import, any source this list does not know, or a run that had read the web,
///   a download, a friend's message, another bot or a third-party tool. Never pinned, never in the system prompt;
///   shown to the model only as labelled, unverified data after the task. The user can review one to promote it.
public enum MemoryTrust: String, Codable, Sendable, Comparable, CaseIterable {
    case untrusted, selfNote, harness, user

    private var rank: Int { switch self { case .untrusted: 0; case .selfNote: 1; case .harness: 2; case .user: 3 } }
    public static func < (a: MemoryTrust, b: MemoryTrust) -> Bool { a.rank < b.rank }

    /// Unknown sources fail closed.
    public static func classify(source: String, tainted: Bool = false) -> MemoryTrust {
        switch source {
        case "user": return .user
        case _ where tainted: return .untrusted
        case "process", "goal": return .harness
        case "self", "learned": return .selfNote
        default: return .untrusted
        }
    }

    /// May this class be part of the system prompt (pinned or in a core block)?
    public var mayEnterPrefix: Bool { self != .untrusted }

    /// What the model is told about it next to the note.
    public var label: String {
        switch self {
        case .user: return "from the user"
        case .harness: return "from the app"
        case .selfNote: return "your own earlier note, unverified"
        case .untrusted: return "unverified, may come from untrusted content"
        }
    }
}

/// Which run and event a tool call belongs to, and whether the run was tainted at that moment. The runtime binds it
/// around every tool execution (task-local, so a tool closure needs no extra parameter) and `MemoryBook` reads it.
public struct RunProvenance: Codable, Equatable, Sendable {
    public var session: String
    /// The model reply that made the call.
    public var eventID: Int
    public var tainted: Bool
    public var taintSources: [String]

    public init(session: String, eventID: Int, tainted: Bool, taintSources: [String] = []) {
        self.session = session
        self.eventID = eventID
        self.tainted = tainted
        self.taintSources = taintSources
    }

    @TaskLocal public static var current: RunProvenance?
}
