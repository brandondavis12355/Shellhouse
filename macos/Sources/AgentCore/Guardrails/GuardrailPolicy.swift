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
            if shellDownloads(arguments["command"]?.asString ?? "", ruleHint: rules), !failedBeforeAnyRemoteContent(observation) {
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
    static func failedBeforeAnyRemoteContent(_ observation: [String: Any]) -> Bool {
        let output = ((observation["stdout"] as? String) ?? "") + "\n" + ((observation["stderr"] as? String) ?? "")
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
        let notGrantable: Set<String> = ["shell.unresolved", "shell.opaque", "path.dynamic", "redirect.dynamic", "args.dynamic", "exec.wrapper", "exec.find_exec", "exec.xargs"]
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
    /// Denied or strictly-blocked attempts before the run is frozen.
    public var maxBlockedActions = 3
    public var maxBytesWritten = 64 * 1024 * 1024
    public init() {}
}

public struct RunGuard: Sendable {
    public enum Violation: Error, CustomStringConvertible, Sendable {
        case rateLimit(Int)
        case shellLimit(Int)
        case blockedLimit(Int)
        case writeQuota(Int)
        case tripwire(String)

        public var description: String {
            switch self {
            case .rateLimit(let n): return "more than \(n) tool calls in a minute"
            case .shellLimit(let n): return "more than \(n) shell commands in one run"
            case .blockedLimit(let n): return "\(n) blocked actions in one run"
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

    public mutating func recordBlocked() throws {
        blocked += 1
        if blocked >= limits.maxBlockedActions { throw Violation.blockedLimit(blocked) }
    }

    public mutating func recordWrite(bytes: Int) throws {
        bytesWritten += bytes
        if bytesWritten > limits.maxBytesWritten { throw Violation.writeQuota(limits.maxBytesWritten) }
    }
}
