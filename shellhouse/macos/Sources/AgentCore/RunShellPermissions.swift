import Foundation

/// "Always allow this binary" decisions for `run_shell`, at two scopes.
///
/// `run_shell` is the one tool `Policy.defaults` always routes through
/// approval, since it's arbitrary command execution — but re-approving the
/// same trusted command (`git status`, `curl`, ...) every single time is
/// pure friction with no safety benefit once you've already said yes once.
/// This is the escape hatch: approve a binary for the rest of this app
/// launch, or permanently on this Mac.
///
/// One instance is meant to be shared across every `AgentRuntime` created
/// during this app's lifetime (see `ContentView`) — "session" means "this
/// running app," not "this one conversation," so a decision made in one
/// chat carries over if you start a new one without quitting the app.
public actor RunShellPermissions {
    public enum Scope: Sendable {
        case session
        case global
    }

    /// "Allow ALL shell commands" grants, distinct from the per-binary lists.
    public enum BlanketScope: Sendable {
        /// This bot only, until the app quits.
        case botSession
        /// This bot only, persisted across launches.
        case botAlways
        /// Every bot, persisted across launches.
        case everyBot
    }

    private var blanketSessionBots: Set<String> = []
    private var blanketPersistentBots: Set<String>
    private var blanketEveryBot: Bool
    private static let blanketBotsKey = "ai.compute.agent.runShellAllowAllBots"
    private static let blanketEveryBotKey = "ai.compute.agent.runShellAllowAllEveryBot"

    private var sessionAllowed: Set<String> = []
    private var globalAllowed: Set<String>
    private static let defaultsKey = "ai.compute.agent.runShellAlwaysAllow"

    public init() {
        globalAllowed = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
        blanketPersistentBots = Set(UserDefaults.standard.stringArray(forKey: Self.blanketBotsKey) ?? [])
        blanketEveryBot = UserDefaults.standard.bool(forKey: Self.blanketEveryBotKey)
    }

    /// `botID` is the bot's sandbox/handle id (what `AgentRuntime` calls `sandboxID`).
    public func isBlanketAllowed(botID: String) -> Bool {
        blanketEveryBot || blanketSessionBots.contains(botID) || blanketPersistentBots.contains(botID)
    }

    public func allowAll(botID: String, scope: BlanketScope) {
        switch scope {
        case .botSession: blanketSessionBots.insert(botID)
        case .botAlways:
            blanketPersistentBots.insert(botID)
            UserDefaults.standard.set(Array(blanketPersistentBots), forKey: Self.blanketBotsKey)
        case .everyBot:
            blanketEveryBot = true
            UserDefaults.standard.set(true, forKey: Self.blanketEveryBotKey)
        }
    }

    public func revokeAll(botID: String, scope: BlanketScope) {
        switch scope {
        case .botSession: blanketSessionBots.remove(botID)
        case .botAlways:
            blanketPersistentBots.remove(botID)
            UserDefaults.standard.set(Array(blanketPersistentBots), forKey: Self.blanketBotsKey)
        case .everyBot:
            blanketEveryBot = false
            UserDefaults.standard.set(false, forKey: Self.blanketEveryBotKey)
        }
    }

    /// Which blanket grants currently apply to `botID`, for the Settings UI.
    public func blanketScopes(botID: String) -> [BlanketScope] {
        var scopes: [BlanketScope] = []
        if blanketSessionBots.contains(botID) { scopes.append(.botSession) }
        if blanketPersistentBots.contains(botID) { scopes.append(.botAlways) }
        if blanketEveryBot { scopes.append(.everyBot) }
        return scopes
    }

    public func isAllowed(_ binary: String) -> Bool {
        sessionAllowed.contains(binary) || globalAllowed.contains(binary)
    }

    public func allow(_ binary: String, scope: Scope) {
        switch scope {
        case .session:
            sessionAllowed.insert(binary)
        case .global:
            globalAllowed.insert(binary)
            persistGlobal()
        }
    }

    public func revoke(_ binary: String, scope: Scope) {
        switch scope {
        case .session:
            sessionAllowed.remove(binary)
        case .global:
            globalAllowed.remove(binary)
            persistGlobal()
        }
    }

    public func list(scope: Scope) -> [String] {
        (scope == .session ? sessionAllowed : globalAllowed).sorted()
    }

    private func persistGlobal() {
        UserDefaults.standard.set(Array(globalAllowed), forKey: Self.defaultsKey)
    }

    /// Best-effort extraction of the actual command being run, from a
    /// `run_shell` call's `command` argument — the first token that isn't a
    /// leading `VAR=value` environment assignment, with any path stripped
    /// (`/usr/bin/git` and `git` should be the same permission entry).
    /// Deliberately simple: good enough for the common case, not a shell
    /// parser — a command hidden behind `bash -c "..."` or a pipeline just
    /// resolves to "bash", which is still a meaningful (if coarse) unit to
    /// grant trust to.
    public static func extractBinary(fromCommand command: String) -> String? {
        var tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            tokens.removeFirst()
        }
        guard let first = tokens.first, !first.isEmpty else { return nil }
        return (first as NSString).lastPathComponent
    }
}
