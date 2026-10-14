import Foundation

// Provenance + the combined decision (docs/GUARDRAILS.md, L2/L3).

public enum TaintSource: String, Codable, Sendable {
    /// A friend's message is in the conversation (a live, possibly hostile, human).
    case friendMessage
    case web
    case mcp
    case download
    case browser
    case peerBot
    case thirdPartySkill
}

/// Whether untrusted content has entered a run. Monotonic: once tainted, a
/// run stays tainted (start a fresh run to get a clean one).
public struct TaintState: Sendable {
    public private(set) var sources: [TaintSource] = []
    public init(sources: [TaintSource] = []) {
        for s in sources { mark(s) }
    }
    public var isTainted: Bool { !sources.isEmpty }
    public var hasFriend: Bool { sources.contains(.friendMessage) }

    /// Returns true if this call newly tainted the run.
    @discardableResult
    public mutating func mark(_ source: TaintSource) -> Bool {
        let wasClean = !isTainted
        if !sources.contains(source) { sources.append(source) }
        return wasClean
    }

    public var summary: String { sources.map(\.rawValue).joined(separator: ", ") }
}

public enum TaintRules {
    /// Which untrusted sources a finished tool call introduced into context.
    public static func sources(
        tool: String,
        arguments: [String: AnyCodable],
        rules: [String],
        observation: [String: Any],
        browserEngaged: Bool
    ) -> [TaintSource] {
        var out: [TaintSource] = []
        switch tool {
        case "web_search", "fetch_url": out.append(.web)
        case "use_skill":
            if let name = arguments["name"]?.asString, SkillLibrary.isUserSkill(id: name) { out.append(.thirdPartySkill) }
        case "message_bot":
            if (observation["_tainted"] as? Bool) == true { out.append(.peerBot) }
        case "screenshot":
            if browserEngaged { out.append(.browser) }
        case "run_shell":
            let command = arguments["command"]?.asString ?? ""
            if shellDownloads(command, ruleHint: rules), !failedBeforeAnyRemoteContent(observation),
               !fromTrustedGitHubOwner(command, observation: observation, trusted: GuardrailConfig.trustedGitHubOwners),
               !gitBroughtNothingIn(command, observation: observation) {
                out.append(.download)
            }
        default:
            if tool.hasPrefix("mcp__") { out.append(.mcp) }
        }
        return out
    }

    /// Does this shell command bring outside content into context? Judged command by command: a download
    /// (curl, git clone, pip/npm install, ...) does; installing from the distro's signed repositories
    /// (`apt`, `apt-get`, `dpkg`, even with `sudo`) does not, and neither does anything that only reads
    /// local files — so one bundled `apt-get update; find / ...; dpkg -l | grep gh` is not "untrusted".
    static func shellDownloads(_ command: String, ruleHint rules: [String]) -> Bool {
        guard rules.contains(where: { $0.hasPrefix("network.") || $0.hasPrefix("supply_chain.") }) else { return false }
        let analysis = ShellAnalyzer.analyze(command)
        // Anything we cannot see into stays suspicious.
        guard analysis.unresolved.isEmpty, analysis.opaque.isEmpty, !analysis.commands.isEmpty else { return true }
        let distro: Set<String> = ["apt", "apt-get", "dpkg", "apt-cache", "dpkg-query", "sudo"]
        for cmd in analysis.commands {
            guard let program = cmd.program, !cmd.programIsDynamic else { return true }
            if distro.contains(program) { continue }
            let findings = ActionClassifier.classifyCommand(cmd, analysis: analysis, config: GuardrailConfig())
            if findings.contains(where: { $0.rule.hasPrefix("network.") || $0.rule.hasPrefix("supply_chain.") }) { return true }
        }
        return false
    }

    /// A download that failed locally on authentication, before the remote sent anything: nothing outside
    /// came in, so the run stays trusted and can still use a secret to retry. Any `remote:` line (text the
    /// server chose) or other output keeps the usual taint.
    /// `git clone/pull/fetch` or `gh repo clone` of a repository owned by an account the user trusts (their
    /// own, their org's). The owner comes from the command's URLs, or for a plain `git pull` from git's own
    /// "From https://github.com/<owner>/..." line. Anything else in the command, or any other host, keeps the taint.
    static func fromTrustedGitHubOwner(_ command: String, observation: [String: Any], trusted: Set<String>) -> Bool {
        guard !trusted.isEmpty else { return false }
        let plain = ActionClassifier.withoutExitCodeBoilerplate(command)
        let analysis = ShellAnalyzer.analyze(plain)
        guard ActionClassifier.isSimpleCommandLine(analysis),
              analysis.commands.allSatisfy({ ["git", "gh", "cd", "ls"].contains($0.program ?? "") }) else { return false }
        let output = ((observation["stdout"] as? String) ?? "") + "\n" + ((observation["stderr"] as? String) ?? "")
        let hostPattern = #"(?:https://|git@)([A-Za-z0-9.-]+)[/:]([A-Za-z0-9_.-]+)/"#
        guard let regex = try? NSRegularExpression(pattern: hostPattern) else { return false }
        var owners: [String] = []
        for text in [plain, output] {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let host = Range(match.range(at: 1), in: text), let owner = Range(match.range(at: 2), in: text) else { continue }
                guard text[host].lowercased() == "github.com" else { return false }
                owners.append(text[owner].lowercased())
            }
        }
        // `gh repo clone owner/repo`
        for cmd in analysis.commands where cmd.program == "gh" {
            if let spec = cmd.args.filter({ !$0.hasPrefix("-") }).dropFirst(2).first, spec.contains("/"), !spec.contains(":") {
                owners.append(String(spec.split(separator: "/")[0]).lowercased())
            }
        }
        return !owners.isEmpty && owners.allSatisfy(trusted.contains)
    }

    /// A plain `git fetch`/`pull` against the existing remote (no URL in the command) that printed no `From …`
    /// or `remote:` line: no new commits or server text came in, so there's nothing outside to taint the run.
    static func gitBroughtNothingIn(_ command: String, observation: [String: Any]) -> Bool {
        let plain = ActionClassifier.withoutExitCodeBoilerplate(command)
        guard !plain.contains("://"), !plain.contains("git@") else { return false }
        let analysis = ShellAnalyzer.analyze(plain)
        guard ActionClassifier.isSimpleCommandLine(analysis),
              analysis.commands.allSatisfy({ ["git", "cd", "ls", "echo"].contains($0.program ?? "") }) else { return false }
        let output = ((observation["stdout"] as? String) ?? "") + "\n" + ((observation["stderr"] as? String) ?? "")
        return !output.split(separator: "\n").contains { $0.hasPrefix("From ") || $0.hasPrefix("remote:") }
    }

    static func failedBeforeAnyRemoteContent(_ observation: [String: Any]) -> Bool {
        let output = ((observation["stdout"] as? String) ?? "") + "\n" + ((observation["stderr"] as? String) ?? "")
        // pip refusing to touch the system Python (PEP 668) downloads nothing.
        if output.contains("externally-managed-environment") || output.contains("This environment is externally managed") {
            return output.count < 3_000
        }
        guard AuthFailure.matches(output), !output.contains("remote:") else { return false }
        // Only git/ssh/gh boilerplate around the failure, and nothing long enough to carry a payload.
        return output.count < 600
    }

    /// Whether this call means the desktop browser is now showing outside content.
    public static func opensBrowser(tool: String, arguments: [String: AnyCodable]) -> Bool {
        if tool == "open_app" { return arguments["app"]?.asString == "browser" }
        return false
    }
}

public struct GuardrailDecision: Sendable {
    public var verdict: Verdict
    public var effect: EffectClass
    public var reasons: [String]
    public var rules: [String]
    public var tripwire: Bool
    /// Hold the state change for the user instead of applying it.
    public var quarantine: Bool
    /// Standing "always allow" grants may satisfy this ask.
    public var grantable: Bool
    public var checkpointPaths: [String]
    public var tainted: Bool

    public var isStrict: Bool { verdict >= .askStrict }
}

public enum GuardrailPolicy {
    /// Tools whose durable effect is held for review when the run is tainted.
    public static let quarantinedTools: Set<String> = ["remember", "save_evidence", "create_routine", "edit_routine"]

    /// Rules that stay with the user in an untrusted run even when their effect looks local.
    static let neverReviewedWhenTainted: Set<String> = [
        "shell.opaque", "shell.unresolved", "shell.remote_exec", "shell.fetch_then_exec", "exec.wrapper", "exec.find_exec", "exec.xargs",
        "network.dynamic_url", "url.private", "url.unparseable", "url.userinfo", "exec.git_config_read",
    ]

    /// Every finding that escalates in an untrusted run is local work: running, building, editing, installing
    /// or downloading into the VM, or using its desktop.
    static func localOnly(_ classification: Classification) -> Bool {
        let local: Set<EffectClass> = [.observe, .reversibleWrite, .ui, .exec, .network]
        let escalating = classification.findings.filter { $0.tainted >= .askStrict }
        return !escalating.isEmpty && !classification.tripwire
            // Only undoes what the taint added: a finding already strict in a clean run stays strict.
            && escalating.allSatisfy { local.contains($0.effect) && $0.tainted == .askStrict && $0.clean <= .ask
                && !neverReviewedWhenTainted.contains($0.rule) }
    }

    /// Combine the static baseline (`Policy`), the effect classification and
    /// the run's taint into one verdict. Layers only move toward `.deny`; the
    /// single deliberate lowering is the opt-in read-only-shell fast path.
    public static func evaluate(
        tool: String,
        arguments: [String: AnyCodable],
        baseline: Policy.Decision,
        taint: TaintState,
        config: GuardrailConfig = .standard,
        friendSafeTools: Set<String> = []
    ) -> GuardrailDecision {
        let classification = ActionClassifier.classify(tool: tool, arguments: arguments, config: config)
        let tainted = taint.isTainted

        var verdict: Verdict
        switch baseline {
        case .allow: verdict = .allow
        case .requireApproval: verdict = .ask
        case .deny: verdict = .deny
        }

        let classVerdict = classification.verdict(tainted: tainted)
        verdict = max(verdict, classVerdict)

        // The one place the baseline is lowered: provably read-only shell,
        // only when the operator opted in, and never in a tainted run.
        if tool == "run_shell", config.autoAllowReadOnlyShell, !tainted, baseline == .requireApproval,
           classification.rules.contains("shell.read_only"), classVerdict == .allow {
            verdict = .allow
        }

        // Untrusted content can steer what the agent wants to do, but work that stays inside its own VM can't
        // send anything out by itself. Let the fast-model reviewer settle it (it is told the run is untrusted
        // and to be stricter) instead of asking the user every time. Anything that reaches outside the VM,
        // touches credentials, destroys, or can't be fully analyzed still goes to the user.
        if tainted, !taint.hasFriend, verdict == .askStrict, baseline != .deny, localOnly(classification) {
            verdict = .ask
        }

        // A friend's message is a live adversary: anything beyond bookkeeping asks.
        if taint.hasFriend, verdict == .allow, !friendSafeTools.contains(tool) {
            verdict = .ask
        }

        var quarantine = false
        if tainted, quarantinedTools.contains(tool), verdict == .allow {
            quarantine = true
        }

        if classification.tripwire { verdict = .deny }

        // Never grantable: anything whose real effect is computed at run time.
        // Also never standing grants: the reviewer-settled exceptions below are judged one call at a time.
        let notGrantable: Set<String> = ["write.rm_workspace", "exec.privilege_apt", "external.git_push", "shell.use_secrets_github", "security.gh_setup_git", "shell.unresolved", "shell.opaque", "path.dynamic", "redirect.dynamic", "args.dynamic", "exec.wrapper", "exec.find_exec", "exec.xargs"]
        let grantable = verdict == .ask && !tainted && tool == "run_shell" && classification.rules.allSatisfy { !notGrantable.contains($0) }

        return GuardrailDecision(
            verdict: verdict,
            effect: classification.effect,
            reasons: classification.reasons,
            rules: classification.rules,
            tripwire: classification.tripwire,
            quarantine: quarantine,
            grantable: grantable,
            checkpointPaths: classification.checkpointPaths,
            tainted: tainted
        )
    }
}

// MARK: - Run limits / circuit breaker

public struct RunLimits: Sendable {
    public var maxToolCallsPerMinute = 90
    public var maxShellCommands = 400
    /// Blocked or denied attempts of any kind before the run is frozen (a run hitting this many different
    /// walls is probing them). Blocks are otherwise information the bot acts on.
    public var maxBlockedActions = 8
    /// The same kind of blocked action (same rules), retried this many times, freezes the run.
    public var maxRepeatsOfOneBlock = 3
    public var maxBytesWritten = 64 * 1024 * 1024
    public init() {}
}

public struct RunGuard: Sendable {
    public enum Violation: Error, CustomStringConvertible, Sendable {
        case rateLimit(Int)
        case shellLimit(Int)
        case blockedLimit(Int)
        case repeatedBlock(Int)
        case writeQuota(Int)
        case tripwire(String)

        public var description: String {
            switch self {
            case .rateLimit(let n): return "more than \(n) tool calls in a minute"
            case .shellLimit(let n): return "more than \(n) shell commands in one run"
            case .blockedLimit(let n): return "\(n) blocked actions in one run"
            case .repeatedBlock(let n): return "the same blocked action was tried \(n) times"
            case .writeQuota(let n): return "more than \(n / 1024 / 1024) MB written in one run"
            case .tripwire(let why): return "touched a decoy credential (\(why))"
            }
        }
    }

    public var limits: RunLimits
    private var callTimes: [Date] = []
    private var shellCount = 0
    private(set) public var blocked = 0
    private var bytesWritten = 0

    public init(limits: RunLimits = RunLimits()) { self.limits = limits }

    public mutating func recordCall(tool: String, now: Date = Date()) throws {
        callTimes.append(now)
        callTimes.removeAll { now.timeIntervalSince($0) > 60 }
        if callTimes.count > limits.maxToolCallsPerMinute { throw Violation.rateLimit(limits.maxToolCallsPerMinute) }
        if tool == "run_shell" {
            shellCount += 1
            if shellCount > limits.maxShellCommands { throw Violation.shellLimit(limits.maxShellCommands) }
        }
    }

    private var blockedByKind: [String: Int] = [:]

    /// `kind` groups rewordings of the same blocked thing (its rules), so retrying it is caught early.
    public mutating func recordBlocked(kind: String = "") throws {
        blocked += 1
        if !kind.isEmpty {
            blockedByKind[kind, default: 0] += 1
            if blockedByKind[kind]! >= limits.maxRepeatsOfOneBlock { throw Violation.repeatedBlock(blockedByKind[kind]!) }
        }
        if blocked >= limits.maxBlockedActions { throw Violation.blockedLimit(blocked) }
    }

    public mutating func recordWrite(bytes: Int) throws {
        bytesWritten += bytes
        if bytesWritten > limits.maxBytesWritten { throw Violation.writeQuota(limits.maxBytesWritten) }
    }
}
