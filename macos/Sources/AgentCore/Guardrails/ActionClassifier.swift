import Foundation

// Classifies a tool call by its *effect*, not its name (docs/GUARDRAILS.md,
// L1). Rules are data + small matchers; every rule has an id so tests and the
// audit log can point at exactly which rule fired.

public enum EffectClass: String, Codable, Sendable, CaseIterable {
    /// Reads / lists / looks. No state change.
    case observe
    /// Reversible change inside the workspace (checkpointable).
    case reversibleWrite
    /// Network egress.
    case network
    /// Drives the sandbox desktop (click / type / open app).
    case ui
    /// Runs code or a command we can't prove read-only.
    case exec
    /// Irreversible or wide-blast-radius.
    case destructive
    /// Touches credentials, keys, persistence, or disables a control.
    case credential
    /// Visible outside the sandbox / this app (push, post, publish, create bot).
    case external
    /// This app's own durable state (memory, routines).
    case state
}

/// How strongly a call must be gated. Layers can only move RIGHT.
public enum Verdict: Int, Comparable, Codable, Sendable {
    case allow = 0
    /// Ask the human. Standing grants may apply (clean run, exec class only).
    case ask = 1
    /// Ask the human every single time; no standing grant applies or is created.
    case askStrict = 2
    /// Never runs.
    case deny = 3

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Finding: Sendable {
    public let effect: EffectClass
    public let rule: String
    public let reason: String
    /// Verdict implied in a run with no untrusted content in context.
    public let clean: Verdict
    /// Verdict implied once untrusted content has entered the run.
    public let tainted: Verdict
    /// Touching this means the agent is hunting for secrets: freeze the run.
    public var tripwire = false
    /// For deletions inside the workspace: paths worth snapshotting first.
    public var checkpointPaths: [String] = []

    public init(_ effect: EffectClass, _ rule: String, _ reason: String, clean: Verdict, tainted: Verdict,
                tripwire: Bool = false, checkpointPaths: [String] = []) {
        self.effect = effect
        self.rule = rule
        self.reason = reason
        self.clean = clean
        self.tainted = tainted
        self.tripwire = tripwire
        self.checkpointPaths = checkpointPaths
    }
}

public struct Classification: Sendable {
    public var findings: [Finding]

    public var effect: EffectClass {
        // The most severe finding's class represents the call.
        findings.max(by: { $0.clean < $1.clean })?.effect ?? .observe
    }
    public func verdict(tainted: Bool) -> Verdict {
        findings.map { tainted ? $0.tainted : $0.clean }.max() ?? .allow
    }
    public var tripwire: Bool { findings.contains { $0.tripwire } }
    public var reasons: [String] { findings.filter { $0.clean > .allow || $0.tainted > .allow }.map(\.reason) }
    public var rules: [String] { findings.map(\.rule) }
    public var checkpointPaths: [String] { findings.flatMap(\.checkpointPaths) }
    /// True when every finding is plain read-only.
    public var isReadOnly: Bool { findings.allSatisfy { $0.effect == .observe && $0.clean == .allow } }
}

public struct GuardrailConfig: Sendable {
    public var home = "/home/box"
    public var cwd = "/workspace"
    /// Paths the agent may modify without it counting as "outside".
    public var writableRoots = ["/workspace", "/home/box", "/tmp"]
    /// Lets provably read-only shell pipelines (`ls | grep x`) run without a
    /// prompt. Off by default: it is the one place the policy lowers the
    /// baseline, so it is an explicit opt-in.
    public var autoAllowReadOnlyShell = false
    /// YOLO mode: skip the approval prompt for ordinary, clean-run actions. It never lifts a hard
    /// block, and runs that have read untrusted content (web, downloads, files, friends) still ask.
    public var yolo = false
    public init() {}
    public static let yoloKey = "guardrails.yolo"

    /// Opt-ins read from UserDefaults (App Settings).
    public static var standard: GuardrailConfig {
        var config = GuardrailConfig()
        config.autoAllowReadOnlyShell = UserDefaults.standard.bool(forKey: "guardrails.autoAllowReadOnlyShell")
        config.yolo = UserDefaults.standard.bool(forKey: GuardrailConfig.yoloKey)
        return config
    }
}

// MARK: - Path rules

public enum PathRules {
    /// Decoys planted by `sandbox/bin/seed-canaries.sh`. Any touch is a tripwire.
    public static let canaryPaths: Set<String> = [
        "/home/box/.aws/credentials",
        "/home/box/.ssh/id_ed25519",
        "/home/box/.config/gcloud/application_default_credentials.json",
        "/workspace/.env.production",
    ]

    /// Sample sensitive paths used to test whether a glob could reach one.
    static let sensitiveSamples: [String] = [
        "/home/box/.ssh/id_rsa", "/home/box/.ssh/id_ed25519", "/home/box/.ssh/authorized_keys",
        "/home/box/.aws/credentials", "/home/box/.config/gcloud/application_default_credentials.json",
        "/home/box/.config/gh/hosts.yml", "/home/box/.kube/config", "/home/box/.docker/config.json",
        "/home/box/.netrc", "/home/box/.git-credentials", "/etc/shadow", "/etc/sudoers",
        "/home/box/.gnupg/private-keys-v1.d/key.key", "/workspace/.env.production", "/workspace/.env",
        "/home/box/.bashrc", "/home/box/.profile", "/proc/self/environ", "/proc/1/environ", "/home/box/.bash_history",
    ]

    private static let credentialDenyPatterns: [(regex: String, why: String)] = [
        (#"/\.ssh(/|$)"#, "SSH keys/config"),
        (#"/\.gnupg(/|$)"#, "GPG keys"),
        (#"^/etc/(shadow|gshadow|sudoers)(\.d(/.*)?)?$"#, "system credential file"),
        (#"^/proc/[^/]+/(task/[^/]+/)?(environ|mem|maps|auxv|cmdline|fd(/.*)?|exe)$"#, "process memory/environment"),
        (#"^/proc/(kcore|kallsyms|kmsg|keys)$"#, "kernel memory"),
        (#"^/dev/(mem|kmem|port|sd[a-z]\d*|nvme\d.*|vd[a-z]\d*|hd[a-z]\d*|disk.*)$"#, "raw device"),
        (#"^/etc/(shadow|gshadow)-?$"#, "system credential file"),
        (#"^/etc/ssh/ssh_host_.*_key$"#, "SSH host key"),
        (#"^/etc/ssl/private(/|$)"#, "TLS private keys"),
        (#"^/etc/(krb5\.keytab|security/opasswd|kubernetes/.*\.conf|docker/key\.json)$"#, "system credential file"),
        (#"^/(var/)?run/secrets(/|$)"#, "mounted secrets"),
        (#"^/var/run/secrets(/|$)"#, "service account secrets"),
        (#"^/var/run/docker\.sock$|^/run/docker\.sock$"#, "container runtime socket"),
        (#"^/root/\.(ssh|aws|gnupg|kube|docker|netrc|bash_history)(/|$)"#, "root credentials"),
        (#"/\.(bash|zsh|python|psql|mysql|node_repl|sh|lesshst|viminfo)_?history$|/\.(lesshst|viminfo)$"#, "shell/tool history (may contain secrets)"),
        (#"/\.vault-token$"#, "Vault token"),
        (#"/\.terraform\.d/credentials"#, "Terraform credentials"),
        (#"/\.cargo/credentials"#, "cargo credentials"),
        (#"/\.gem/credentials$"#, "gem credentials"),
        (#"/\.config/(git/credentials|rclone|op|glab-cli|hub|doctl|Bitwarden|1Password|Slack|discord)(/|$)"#, "tool credentials"),
        (#"/\.(s3cfg|boto|oci)(/|$)"#, "cloud credentials"),
        (#"/\.password-store(/|$)"#, "password store"),
        (#"/\.pki/nssdb(/|$)"#, "NSS key store"),
        (#"/\.config/(BraveSoftware|microsoft-edge|vivaldi|opera|Code/User/globalStorage)(/|$)"#, "browser/editor profile (cookies, tokens)"),
        (#"/\.aws(/|$)"#, "AWS credentials"),
        (#"/\.config/gcloud(/|$)"#, "Google Cloud credentials"),
        (#"/\.azure(/|$)"#, "Azure credentials"),
        (#"/\.kube/config$"#, "Kubernetes credentials"),
        (#"/\.docker/config\.json$"#, "Docker registry credentials"),
        (#"/\.netrc$"#, ".netrc credentials"),
        (#"/\.git-credentials$"#, "git credentials"),
        (#"/\.config/gh(/|$)"#, "GitHub CLI token"),
        (#"/\.config/(chromium|google-chrome|chrome)(/|$)"#, "browser profile (cookies, saved logins)"),
        (#"/\.mozilla(/|$)"#, "browser profile (cookies, saved logins)"),
        (#"/\.local/share/keyrings(/|$)"#, "keyring"),
        (#"(^|/)(Login Data|Cookies|cookies\.sqlite|key[34]\.db|logins\.json)$"#, "browser credential store"),
    ]

    private static let credentialSensitivePatterns: [(regex: String, why: String)] = [
        (#"(^|/)\.env(\..+)?$"#, "environment/secrets file"),
        (#"\.(pem|key|p12|pfx|jks|keystore)$"#, "private key / certificate file"),
        (#"(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$"#, "SSH key file"),
        (#"(^|/)(credentials|secrets?)(\.[a-z0-9]+)*$"#, "credentials file"),
        (#"(^|/)\.(yarnrc|m2/settings\.xml|gradle/gradle\.properties)$|/\.m2/settings\.xml$|/\.gradle/gradle\.properties$"#, "package manager credentials"),
        (#"(^|/)\.(npmrc|pypirc|pgpass|my\.cnf)$"#, "package/database credentials"),
    ]

    private static let persistencePatterns: [(regex: String, why: String)] = [
        (#"/\.(bashrc|bash_profile|bash_login|bash_logout|profile|zshrc|zprofile|zlogin|zlogout|zshenv)$"#, "shell startup file (persistence)"),
        (#"/\.config/autostart(/|$)"#, "autostart entry (persistence)"),
        (#"/\.config/openbox/autostart$"#, "desktop autostart (persistence)"),
        (#"/\.config/systemd(/|$)"#, "user service (persistence)"),
        (#"^/etc(/|$)"#, "system configuration"),
        (#"^/root(/|$)"#, "root's home"),
        (#"^/var/spool/cron"#, "cron (persistence)"),
        (#"/\.git/(hooks|config|info)(/|$)"#, "git hook/config (persistence)"),
        (#"/\.husky(/|$)"#, "git hook (persistence)"),
        (#"/\.(gitconfig|bash_aliases|inputrc|xinitrc|xprofile|xsession|pam_environment|vimrc|npmrc|ssh/rc)$"#, "startup/config file (persistence)"),
        (#"/\.config/(git|fish|environment\.d|nvim|pip|openbox)(/|$)"#, "user config (persistence)"),
        (#"/\.local/(bin|share/applications)(/|$)|^/home/[^/]+/bin(/|$)"#, "user executable path (persistence)"),
        (#"^/(proc|sys)(/|$)"#, "kernel interface"),
        (#"^/dev/(?!null$|tty$|stdout$|stderr$|stdin$|fd/[0-9]+$)"#, "device node"),
        (#"^/(usr|bin|sbin|lib|lib64|boot|opt)(/|$)"#, "system binaries / libraries"),
    ]

    private static let compiled: [String: NSRegularExpression] = {
        var map: [String: NSRegularExpression] = [:]
        for entry in credentialDenyPatterns + credentialSensitivePatterns + persistencePatterns {
            map[entry.regex] = try? NSRegularExpression(pattern: entry.regex, options: [.caseInsensitive])
        }
        return map
    }()

    private static func firstMatch(_ patterns: [(regex: String, why: String)], _ path: String) -> String? {
        let range = NSRange(path.startIndex..., in: path)
        for entry in patterns {
            if compiled[entry.regex]?.firstMatch(in: path, range: range) != nil { return entry.why }
        }
        return nil
    }

    public static func isCanary(_ normalized: String) -> Bool { canaryPaths.contains(normalized) }
    public static func credentialDeny(_ normalized: String) -> String? { firstMatch(credentialDenyPatterns, normalized) }
    public static func credentialSensitive(_ normalized: String) -> String? { firstMatch(credentialSensitivePatterns, normalized) }
    public static func persistence(_ normalized: String) -> String? { firstMatch(persistencePatterns, normalized) }

    public static func isWritable(_ normalized: String, config: GuardrailConfig) -> Bool {
        config.writableRoots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    /// Does the glob `pattern` (already home/cwd-resolved) possibly match a sensitive path?
    static func globMayReachSensitive(_ pattern: String, config: GuardrailConfig, wildcardCrossesSlash: Bool = false) -> Bool {
        let abs = ShellAnalyzer.normalize(path: pattern, cwd: config.cwd, home: config.home)
        var regex = "^"
        var i = abs.startIndex
        while i < abs.endIndex {
            let c = abs[i]
            switch c {
            case "*":
                let atComponentStart = i == abs.startIndex || abs[abs.index(before: i)] == "/"
                regex += wildcardCrossesSlash ? ".*" : (atComponentStart ? "(?!\\.)[^/]*" : "[^/]*")
            case "?":
                let atComponentStart = i == abs.startIndex || abs[abs.index(before: i)] == "/"
                regex += atComponentStart && !wildcardCrossesSlash ? "(?!\\.)[^/]" : "[^/]"
            case "[":
                if let close = abs[i...].firstIndex(of: "]") {
                    regex += String(abs[i...close]); i = close
                } else { regex += "\\[" }
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = abs.index(after: i)
        }
        regex += "$"
        guard let re = try? NSRegularExpression(pattern: regex) else { return true }
        return sensitiveSamples.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }
}

// MARK: - Classifier

public enum ActionClassifier {

    // MARK: Tools other than the shell

    public static func classify(tool: String, arguments: [String: AnyCodable], config: GuardrailConfig = .standard) -> Classification {
        switch tool {
        case "run_shell":
            let command = arguments["command"]?.asString ?? ""
            let usesSecrets = !(arguments["use_secrets"]?.asStringArray ?? []).isEmpty
            return classifyShell(command, usesSecrets: usesSecrets, config: config)

        case "list_files", "read_file":
            let path = arguments["path"]?.asString ?? "."
            return Classification(findings: pathFindings(path, mode: .read, config: config) + [
                Finding(.observe, "tool.\(tool)", "reads a file", clean: .allow, tainted: .allow),
            ])

        case "search_files", "find_files":
            let path = arguments["path"]?.asString ?? "."
            return Classification(findings: pathFindings(path, mode: .read, config: config) + [
                Finding(.observe, "tool.\(tool)", "searches the workspace", clean: .allow, tainted: .allow),
            ])

        case "check_job", "stop_job":
            return Classification(findings: [Finding(.observe, "tool.\(tool)", "checks or stops this bot's own background job", clean: .allow, tainted: .allow)])

        case "write_file", "edit_file":
            let path = arguments["path"]?.asString ?? ""
            var findings = pathFindings(path, mode: .write, config: config)
            let normalized = ShellAnalyzer.normalize(path: path, cwd: config.cwd, home: config.home)
            findings.append(Finding(.reversibleWrite, "tool.\(tool)", tool == "edit_file" ? "edits a workspace file" : "writes a workspace file",
                                    clean: .allow, tainted: .allow, checkpointPaths: [normalized]))
            return Classification(findings: findings)

        case "screenshot", "list_windows", "focus_window", "scroll":
            return Classification(findings: [Finding(.observe, "tool.\(tool)", "observes the desktop", clean: .allow, tainted: .allow)])

        case "click", "press_key":
            return Classification(findings: [Finding(.ui, "tool.\(tool)", "drives the sandbox desktop", clean: .allow, tainted: .allow)])

        case "type_text":
            let text = arguments["text"]?.asString ?? ""
            // A long paste into the desktop is a data-egress path (a web form),
            // so it asks once untrusted content has been seen.
            let long = text.count > 256
            // Text typed into a terminal window is a command: judge it as one.
            let typed = classifyShell(text, config: config).findings.filter { $0.clean >= .askStrict }
            return Classification(findings: typed + [Finding(.ui, "tool.type_text", long ? "types a long text block into the desktop" : "types into the desktop",
                                                     clean: .allow, tainted: long ? .ask : .allow)])

        case "open_app":
            let app = arguments["app"]?.asString ?? ""
            if app == "browser", let url = arguments["url"]?.asString, !url.isEmpty {
                return Classification(findings: urlFindings(url) + [Finding(.network, "tool.open_app.url", "opens a URL in the browser", clean: .allow, tainted: .allow)])
            }
            return Classification(findings: [Finding(.ui, "tool.open_app", app == "terminal" ? "opens a terminal (typed text runs as commands)" : "opens an app",
                                                     clean: .allow, tainted: app == "terminal" ? .ask : .allow)])

        case "web_search":
            return Classification(findings: [Finding(.network, "tool.web_search", "searches the web", clean: .allow, tainted: .allow)])

        case "fetch_url":
            let url = arguments["url"]?.asString ?? ""
            return Classification(findings: urlFindings(url) + [Finding(.network, "tool.fetch_url", "fetches a URL", clean: .allow, tainted: .allow)])

        case "remember", "save_evidence", "create_routine", "edit_routine":
            return Classification(findings: [Finding(.state, "tool.\(tool)", "changes this bot's durable state", clean: .allow, tainted: .allow)])

        case "remove_routine":
            return Classification(findings: [Finding(.state, "tool.remove_routine", "removes a routine", clean: .allow, tainted: .askStrict)])

        case "message_bot":
            // Hands text to another agent: injected instructions would travel with it.
            return Classification(findings: [Finding(.external, "tool.message_bot", "delegates text to another bot", clean: .allow, tainted: .askStrict)])

        case "post_to_group", "add_bot_to_group":
            return Classification(findings: [Finding(.external, "tool.\(tool)", "posts to or changes a group (may be shared with friends)", clean: .allow, tainted: .askStrict)])

        case "create_bot":
            return Classification(findings: [Finding(.external, "tool.create_bot", "creates a new bot with its own sandbox", clean: .ask, tainted: .askStrict)])

        case "update_user", "remember_task":
            return Classification(findings: [Finding(.state, "tool.\(tool)", "changes this bot's durable state", clean: .allow, tainted: .askStrict)])

        case "propose_goal", "add_goal_step", "update_goal_step", "propose_goal_complete", "complete_task":
            return Classification(findings: [Finding(.state, "tool.\(tool)", "changes goals or tasks", clean: .allow, tainted: .ask)])

        case "list_bots", "list_tasks", "list_routines", "get_profile",
             "recall_memory", "search_memory", "use_skill", "list_secrets", "get_goal", "ask_helpers", "update_plan":
            return Classification(findings: [Finding(.observe, "tool.\(tool)", "bookkeeping", clean: .allow, tainted: .allow)])

        default:
            if tool.hasPrefix("mcp__") {
                return Classification(findings: [Finding(.external, "tool.mcp", "calls a third-party MCP server", clean: .ask, tainted: .askStrict)])
            }
            return Classification(findings: [Finding(.exec, "tool.unknown", "unrecognized tool", clean: .ask, tainted: .askStrict)])
        }
    }

    // MARK: URLs

    static func urlFindings(_ raw: String) -> [Finding] {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else {
            return [Finding(.network, "url.unparseable", "URL could not be parsed", clean: .ask, tainted: .askStrict)]
        }
        var out: [Finding] = []
        if !["http", "https"].contains(scheme) {
            out.append(Finding(.credential, "url.scheme", "non-web URL scheme (\(scheme):)", clean: .askStrict, tainted: .deny))
            if scheme == "file" { out += pathFindings(url.path, mode: .read, config: GuardrailConfig()).filter { $0.effect == .credential } }
        }
        if url.user != nil || url.password != nil {
            out.append(Finding(.network, "url.userinfo", "URL carries embedded credentials", clean: .askStrict, tainted: .deny))
        }
        if let host = url.host?.lowercased() {
            let cls = hostClass(host)
            if cls.metadata {
                out.append(Finding(.credential, "url.metadata", "cloud metadata endpoint", clean: .deny, tainted: .deny, tripwire: true))
            } else if cls.private || isPrivateHost(host) {
                out.append(Finding(.network, "url.private", "private / loopback address", clean: .ask, tainted: .askStrict))
            }
        }
        return out
    }

    static func looksLikeHostArg(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(" "), !s.hasPrefix("/"), !s.hasPrefix("@"), !s.hasPrefix("$") else { return false }
        let hostPart = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        return hostPart.contains(".") || hostPart.contains(":") || hostPart.hasPrefix("[") || hostPart == "localhost" || hostPart.allSatisfy(\.isNumber)
    }

    /// inet_aton-style IPv4 (decimal, octal, hex, 1-4 parts) -> 32-bit value.
    static func parseLegacyIPv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count) else { return nil }
        var nums: [UInt64] = []
        for p in parts {
            guard !p.isEmpty else { return nil }
            var v: UInt64?
            if p.lowercased().hasPrefix("0x") { v = UInt64(p.dropFirst(2), radix: 16) }
            else if p.count > 1, p.hasPrefix("0") { v = UInt64(p.dropFirst(1), radix: 8) }
            else { v = UInt64(p, radix: 10) }
            guard let n = v else { return nil }
            nums.append(n)
        }
        var value: UInt64 = 0
        for (i, n) in nums.enumerated() {
            if i == nums.count - 1 {
                let bits = 8 * (5 - nums.count)
                guard n < (UInt64(1) << UInt64(bits)) else { return nil }
                value = (value << UInt64(bits)) | n
            } else {
                guard n < 256 else { return nil }
                value = (value << 8) | n
            }
        }
        return UInt32(truncatingIfNeeded: value)
    }

    static func ipv4Class(_ v: UInt32) -> (private: Bool, metadata: Bool) {
        let a = Int(v >> 24), b = Int((v >> 16) & 255)
        let metadata = v == 0xA9FEA9FE || v == 0xA9FEAA02 || v == 0x646464C8
        let priv = a == 10 || a == 127 || a == 0 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
        return (priv, metadata || (a == 169 && b == 254))
    }

    static func hostClass(_ rawHost: String) -> (private: Bool, metadata: Bool) {
        var host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return (false, false) }
        if ["metadata.google.internal", "metadata.goog", "instance-data", "metadata"].contains(host) { return (true, true) }
        if host.contains(":") {
            var addr = in6_addr()
            guard inet_pton(AF_INET6, host, &addr) == 1 else { return (true, false) }
            let b = withUnsafeBytes(of: &addr) { Array($0) }
            if b.dropLast().allSatisfy({ $0 == 0 }) { return (true, false) }          // ::, ::1
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {      // v4-mapped
                return ipv4Class(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
            }
            if b[0..<12].allSatisfy({ $0 == 0 }) { return ipv4Class(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])) }
            if b[0] == 0xfd, b[1] == 0x00, b[2] == 0x0e, b[3] == 0xc2 { return (true, true) }   // fd00:ec2::/32 (AWS IMDS)
            return ((b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80), false)
        }
        if let v = parseLegacyIPv4(host) { return ipv4Class(v) }
        let labels = host.split(separator: ".")
        if labels.count == 1 { return (true, false) }          // intranet single-label name
        let privateSuffixes = [".localhost", ".local", ".internal", ".lan", ".home", ".corp", ".intranet", ".svc", ".cluster.local", ".home.arpa"]
        return (privateSuffixes.contains { host.hasSuffix($0) }, false)
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "::1" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") }
        if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 169, parts[1] == 254 { return true }
        return false
    }

    // MARK: Paths

    enum PathMode { case read, write, delete }

    static func pathFindings(_ raw: String, mode: PathMode, dynamic: Bool = false, config: GuardrailConfig) -> [Finding] {
        var out: [Finding] = []
        var dynamic = dynamic
        if raw.contains("\0") || raw.utf8.count > 4096 || raw.contains("\n") {
            out.append(Finding(.credential, "path.malformed", "path contains control characters or is excessively long", clean: .askStrict, tainted: .deny))
        }
        if raw.contains("$") || raw.contains("`") { dynamic = true }
        let hasGlob = raw.contains("*") || raw.contains("?") || raw.contains("[")
        let normalized = ShellAnalyzer.normalize(path: raw, cwd: config.cwd, home: config.home)

        if hasGlob, PathRules.globMayReachSensitive(raw, config: config) {
            out.append(Finding(.credential, "path.glob_sensitive", "glob pattern could reach credential files (\(raw))",
                               clean: .askStrict, tainted: .deny))
        }
        if PathRules.isCanary(normalized) {
            out.append(Finding(.credential, "path.canary", "touches a decoy credential file", clean: .deny, tainted: .deny, tripwire: true))
            return out
        }
        if let why = PathRules.credentialDeny(normalized) {
            out.append(Finding(.credential, "path.credential", "\(why): \(normalized)", clean: .deny, tainted: .deny))
        } else if let why = PathRules.credentialSensitive(normalized) {
            out.append(Finding(.credential, "path.sensitive", "\(why): \(normalized)", clean: .askStrict, tainted: .deny))
        }
        if mode != .read {
            if let why = PathRules.persistence(normalized) {
                out.append(Finding(.credential, "path.persistence", "\(why): \(normalized)", clean: .deny, tainted: .deny))
            } else if !PathRules.isWritable(normalized, config: config) {
                out.append(Finding(.destructive, "path.outside_workspace", "modifies a path outside the workspace: \(normalized)",
                                   clean: .askStrict, tainted: .deny))
            }
        }
        if dynamic && mode != .read {
            out.append(Finding(.exec, "path.dynamic", "target path is computed at run time", clean: .ask, tainted: .askStrict))
        }
        return out
    }


    // MARK: disguised paths

    /// Strict-or-worse path findings for text that is only partly known
    /// (`$X/.ssh/id_rsa`, `~/.s{s,}h/key`, `-d@file`, `--out=/etc/x`).
    static func credentialScan(_ raw: String, mode: PathMode, config: GuardrailConfig) -> [Finding] {
        var candidates: [String] = [raw]
        if let eq = raw.firstIndex(of: "=") { candidates.append(String(raw[raw.index(after: eq)...])) }
        if let at = raw.firstIndex(of: "@") { candidates.append(String(raw[raw.index(after: at)...])) }
        if let slash = raw.firstIndex(of: "/") { candidates.append(String(raw[slash...])) }
        if let tilde = raw.firstIndex(of: "~") { candidates.append(String(raw[tilde...])) }
        var expanded: [String] = []
        for c in candidates { expanded += braceExpand(c) }
        var out: [Finding] = []
        for c in expanded {
            // Replace remaining expansions with a wildcard that may cross `/`.
            let cleaned = c.replacingOccurrences(of: #"\$\{[^}]*\}|\$\([^)]*\)|`[^`]*`|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?!$-]"#, with: "\u{1}", options: .regularExpression)
            let hasWild = cleaned.contains("\u{1}")
            var texts = [cleaned]
            if hasWild { texts.append(cleaned.replacingOccurrences(of: "\u{1}", with: "")) }
            for t in texts {
                let n = ShellAnalyzer.normalize(path: t.replacingOccurrences(of: "\u{1}", with: "x"), cwd: config.cwd, home: config.home)
                out += pathFindings(t.replacingOccurrences(of: "\u{1}", with: "x"), mode: mode, config: config).filter { $0.effect == .credential }
                if hasWild, t == cleaned, cleaned != "\u{1}" {
                    let glob = cleaned.replacingOccurrences(of: "\u{1}", with: "*")
                    if PathRules.globMayReachSensitive(glob, config: config, wildcardCrossesSlash: true) {
                        out.append(Finding(.credential, "path.glob_sensitive", "computed path could reach credential files (\(raw))", clean: .askStrict, tainted: .deny))
                    }
                }
                _ = n
            }
        }
        return out
    }

    /// Bounded brace expansion (`{a,b}`, `{1..3}`); returns the input if none.
    static func braceExpand(_ text: String, limit: Int = 64) -> [String] {
        var results = [text]
        var guardCount = 0
        while guardCount < 8 {
            guardCount += 1
            var next: [String] = []
            var changed = false
            for r in results {
                guard let open = r.firstIndex(of: "{"), let close = r[open...].firstIndex(of: "}") else { next.append(r); continue }
                let inner = String(r[r.index(after: open)..<close])
                let prefix = String(r[..<open]), suffix = String(r[r.index(after: close)...])
                if inner.contains(",") {
                    for part in inner.split(separator: ",", omittingEmptySubsequences: false) { next.append(prefix + part + suffix) }
                    changed = true
                } else if inner.contains(".."), let range = Optional(inner.components(separatedBy: "..")), range.count == 2, let a = Int(range[0]), let b = Int(range[1]), abs(b - a) < 16 {
                    for v in (a <= b ? Array(a...b) : Array(b...a)) { next.append(prefix + String(v) + suffix) }
                    changed = true
                } else { next.append(r) }
            }
            results = Array(next.prefix(limit))
            if !changed { break }
        }
        return results
    }

    /// Files a program writes, named by its options.
    static func writtenOptionTargets(name: String, args: [String], config: GuardrailConfig) -> [Finding] {
        var targets: [String] = []
        func next(_ flags: Set<String>) {
            for (i, a) in args.enumerated() {
                if flags.contains(a), i + 1 < args.count { targets.append(args[i + 1]) }
            }
        }
        func attached(_ prefixes: [String]) {
            for a in args { for p in prefixes where a.hasPrefix(p) && a.count > p.count { targets.append(String(a.dropFirst(p.count))) } }
        }
        switch name {
        case "curl": next(["-o", "--output", "--output-dir", "-D", "--dump-header", "-c", "--cookie-jar", "--trace", "--stderr"]); attached(["--output=", "--output-dir=", "-o"])
        case "wget": next(["-O", "--output-document", "-P", "--directory-prefix", "-o", "--output-file"]); attached(["--output-document=", "--directory-prefix=", "-O", "-P"])
        case "aria2c": next(["-o", "-d", "--out", "--dir"]); attached(["--out=", "--dir="])
        case "sort": next(["-o", "--output"]); attached(["--output="])
        case "find": for (i, a) in args.enumerated() where ["-fprint", "-fprintf", "-fls", "-fprint0"].contains(a) && i + 1 < args.count { targets.append(args[i + 1]) }
        case "git": attached(["--output="]); next(["--output"])
        case "tar": next(["-C", "--directory"]); attached(["--directory=", "--file="])
        case "uniq", "xxd", "cp", "mv": break
        default: break
        }
        var out: [Finding] = []
        for t in targets { out += pathFindings(t, mode: .write, config: config) }
        if name == "uniq" || name == "xxd" {
            let ops = operands(args).map(\.0)
            if ops.count >= 2 { out += pathFindings(ops[1], mode: .write, config: config) }
        }
        return out
    }

    // MARK: Shell

    static let readOnlyPrograms: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "pwd", "echo", "printf", "date", "whoami", "id",
        "uname", "df", "du", "stat", "file", "tree", "sort", "uniq", "cut", "tr", "diff", "cmp", "basename", "dirname",
        "realpath", "readlink", "which", "type", "true", "false", "test", "[", "sleep", "seq", "jq", "nl", "tac", "rev",
        "column", "fold", "expand", "hostname", "uptime", "free", "nproc", "apt-cache", "dpkg-query", "hash", "md5sum", "sha1sum", "sha256sum", "sha512sum",
        "cksum", "less", "more", "strings", "hexdump", "xxd", "od", "comm", "paste", "join", "numfmt", "locale", "lscpu",
    ]
    static let gitReadOnly: Set<String> = [
        "status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "ls-tree", "cat-file",
        "rev-list", "grep", "show-ref", "diff-tree", "name-rev", "whatchanged", "version",
    ]
    static let shellsAndInterpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "ash", "python", "python3", "python2", "perl", "ruby", "node", "nodejs",
        "php", "lua", "tclsh", "source", ".", "eval", "awk", "gawk", "mawk", "busybox",
    ]
    static let decoders: Set<String> = ["base64", "xxd", "openssl", "gunzip", "zcat", "bzcat", "xzcat", "uudecode", "basenc", "rot13", "gzip"]
    static let downloaders: Set<String> = ["curl", "wget", "fetch", "lwp-download", "aria2c", "axel"]
    static let miners: Set<String> = ["xmrig", "minerd", "cpuminer", "ethminer", "cgminer", "bfgminer", "t-rex", "nbminer"]
    static let hackTools: Set<String> = ["nmap", "masscan", "zmap", "hydra", "sqlmap", "nikto", "john", "hashcat", "aircrack-ng", "metasploit", "msfconsole", "msfvenom", "responder", "mimikatz", "netcat", "ettercap"]
    static let privilege: Set<String> = ["sudo", "su", "doas", "pkexec", "runuser", "setpriv"]
    static let installers: Set<String> = ["pip", "pip3", "pipx", "npm", "yarn", "pnpm", "npx", "uvx", "bunx", "pnpx", "apt", "apt-get", "dpkg", "gem", "cargo", "go", "brew", "snap", "flatpak", "conda", "uv", "bun", "deno"]
    static let systemModifiers: Set<String> = ["mkfs", "mkfs.ext4", "mkfs.ext3", "mkfs.xfs", "mkfs.btrfs", "mkfs.vfat", "mkswap", "wipefs", "fdisk", "sfdisk", "cfdisk", "parted", "gdisk", "shred", "blkdiscard", "losetup", "cryptsetup"]

    public static func classifyShell(_ command: String, usesSecrets: Bool = false, config: GuardrailConfig = .standard) -> Classification {
        var findings: [Finding] = []
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Classification(findings: [Finding(.observe, "shell.empty", "empty command", clean: .allow, tainted: .allow)])
        }

        if usesSecrets {
            findings.append(Finding(.credential, "shell.use_secrets", "command requests Keychain secrets", clean: .askStrict, tainted: .deny))
        }

        // Whole-string patterns that don't need parsing to be damning.
        findings += rawPatternFindings(trimmed)

        let env = ShellAnalyzer.Environment(home: config.home, cwd: config.cwd)
        let analysis = ShellAnalyzer.analyze(trimmed, environment: env)

        for reason in analysis.unresolved {
            findings.append(Finding(.exec, "shell.unresolved", "cannot be fully analyzed: \(reason)", clean: .ask, tainted: .askStrict))
        }
        for reason in analysis.opaque {
            findings.append(Finding(.exec, "shell.opaque", "runs code that cannot be inspected: \(reason)", clean: .askStrict, tainted: .deny))
        }
        if analysis.hasFunctionDefinition {
            findings.append(Finding(.exec, "shell.function", "defines a shell function", clean: .ask, tainted: .askStrict))
        }
        if analysis.runsInBackground {
            findings.append(Finding(.exec, "shell.background", "starts a background process", clean: .ask, tainted: .askStrict))
        }
        if analysis.hasHeredoc && analysis.commands.contains(where: { isInterpreter($0) }) {
            findings.append(Finding(.exec, "shell.heredoc_exec", "feeds a here-document to an interpreter", clean: .ask, tainted: .askStrict))
        }

        let names = analysis.commands.compactMap { cmd -> String? in cmd.program.flatMap(ShellAnalyzer.recognizedName(of:)) }
        // Pipelines that fetch or decode and then execute.
        if analysis.hasPipe {
            let fetches = names.contains { downloaders.contains($0) || $0 == "nc" || $0 == "ncat" }
            let decodes = names.contains { decoders.contains($0) }
            let executes = names.contains { shellsAndInterpreters.contains($0) } || names.contains("xargs")
            if fetches && executes {
                findings.append(Finding(.credential, "shell.remote_exec", "pipes downloaded content into a shell/interpreter", clean: .deny, tainted: .deny))
            } else if decodes && executes {
                findings.append(Finding(.credential, "shell.decode_exec", "decodes data and executes it", clean: .deny, tainted: .deny))
            }
        }

        let fetchesAny = names.contains { downloaders.contains($0) }
        let executesAny = analysis.commands.contains { c in
            guard let p = c.program else { return false }
            if let n = ShellAnalyzer.recognizedName(of: p) { return shellsAndInterpreters.contains(n) }
            return true   // run by path
        }
        if fetchesAny && executesAny && (analysis.hasCommandSubstitution || analysis.hasProcessSubstitution) {
            findings.append(Finding(.credential, "shell.remote_exec", "executes the output of a download", clean: .deny, tainted: .deny))
        } else if fetchesAny && executesAny {
            findings.append(Finding(.credential, "shell.fetch_then_exec", "downloads content and runs code in one command", clean: .askStrict, tainted: .deny))
        }
        for r in dangerousEnvRegexes where r.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            findings.append(Finding(.credential, "shell.env_injection", "sets an environment variable that injects code or redirects execution", clean: .askStrict, tainted: .deny))
            break
        }
        for cmd in analysis.commands {
            findings += classifyCommand(cmd, analysis: analysis, config: config)
        }

        if findings.isEmpty {
            findings.append(Finding(.exec, "shell.generic", "runs a command", clean: .ask, tainted: .askStrict))
        }

        // Read-only fast path: every command provably read-only, nothing unresolved.
        if analysis.isFullyResolved, !analysis.runsInBackground, !analysis.hasFunctionDefinition, !analysis.hasControlFlow,
           !analysis.commands.isEmpty,
           findings.allSatisfy({ $0.effect == .observe }) {
            let reasonText = "read-only commands only"
            findings = findings.map { f in
                Finding(f.effect, f.rule, f.reason, clean: config.autoAllowReadOnlyShell ? .allow : .ask,
                        tainted: config.autoAllowReadOnlyShell ? .allow : .ask,
                        tripwire: f.tripwire, checkpointPaths: f.checkpointPaths)
            }
            findings.append(Finding(.observe, "shell.read_only", reasonText,
                                    clean: config.autoAllowReadOnlyShell ? .allow : .ask,
                                    tainted: config.autoAllowReadOnlyShell ? .allow : .ask))
        }
        return Classification(findings: findings)
    }

    // MARK: raw-string patterns

    private static let rawPatterns: [(regex: String, rule: String, reason: String)] = [
        (#":\s*\(\s*\)\s*\{[^}]*:\s*\|\s*:?\s*&"#, "shell.forkbomb", "fork bomb"),
        (#"/dev/(tcp|udp)/"#, "shell.devtcp", "opens a raw network socket via /dev/tcp"),
        (#"\bbash\s+-i\b.*[<>]&"#, "shell.revshell", "reverse shell"),
        (#"\bn(c|cat|etcat)\b[^|;&]*\s-[a-zA-Z]*[ec]\b"#, "shell.nc_exec", "netcat with -e/-c (remote shell)"),
        (#"\b(socat)\b[^|;&]*\b(exec|system):"#, "shell.socat_exec", "socat remote shell"),
        (#"stratum\+(tcp|ssl)://"#, "shell.miner_pool", "cryptocurrency mining pool"),
        (#"\bpty\.spawn\b|\bsocket\.socket\b[\s\S]*\b(subprocess|os\.dup2|/bin/(ba)?sh)\b"#, "shell.py_revshell", "script that opens a socket and a shell"),
        (#"\bLD_PRELOAD\s*="#, "shell.ld_preload", "LD_PRELOAD injection"),
        (#"\bHISTFILE\s*=\s*(/dev/null)?\s*(;|&|$)|\bunset\s+HISTFILE\b|\bhistory\s+-[cdw]\b"#, "shell.cover_tracks", "clears shell history"),
        (#">\s*/dev/(sd[a-z]|nvme\d|vd[a-z]|hd[a-z]|mem|kmem|port|disk)"#, "shell.raw_device_write", "writes to a raw device"),
        (#"\brm\s+(-[a-zA-Z]*\s+)*--no-preserve-root"#, "shell.no_preserve_root", "rm --no-preserve-root"),
        (#"\bof=/dev/(sd[a-z]|nvme\d|vd[a-z]|hd[a-z]|mem|kmem|port|disk)"#, "shell.dd_raw_device", "dd onto a raw device"),
    ]

    static let dangerousEnvRegexes: [NSRegularExpression] = [
        #"(^|[\s;&|(])(export\s+|declare\s+-x\s+|readonly\s+|env\s+(-\S+\s+)*)?(LD_[A-Z_]+|DYLD_[A-Z_]+|BASH_ENV|ENV|PROMPT_COMMAND|PYTHONSTARTUP|NODE_OPTIONS|PERL5OPT|RUBYOPT|GIT_SSH_COMMAND|GIT_SSH|GIT_EXTERNAL_DIFF|GIT_PAGER|GIT_ASKPASS|SSH_ASKPASS|GIT_PROXY_COMMAND|GIT_EXEC_PATH|GIT_CONFIG_[A-Z_]+|PAGER|LESSOPEN|LESSCLOSE|SHELLOPTS|BASHOPTS|PS4|IFS|PATH|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS)=|\b(shopt\s+-s\s+\S*(dotglob|expand_aliases))|\bset\s+-o\s+allexport"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let compiledRaw: [(NSRegularExpression, String, String)] = rawPatterns.compactMap {
        guard let re = try? NSRegularExpression(pattern: $0.regex, options: [.caseInsensitive]) else { return nil }
        return (re, $0.rule, $0.reason)
    }

    static func rawPatternFindings(_ command: String) -> [Finding] {
        var out: [Finding] = []
        let range = NSRange(command.startIndex..., in: command)
        for (re, rule, reason) in compiledRaw where re.firstMatch(in: command, range: range) != nil {
            out.append(Finding(.credential, rule, reason, clean: .deny, tainted: .deny))
        }
        return out
    }

    // MARK: per command

    static func isInterpreter(_ cmd: ShellCommand) -> Bool {
        guard let p = cmd.program, let n = ShellAnalyzer.recognizedName(of: p) else { return false }
        return shellsAndInterpreters.contains(n)
    }

    static func hasFlag(_ args: [String], short: Set<Character> = [], long: Set<String> = []) -> Bool {
        for a in args {
            if a == "--" { break }
            if a.hasPrefix("--") { if long.contains(String(a.dropFirst(2)).split(separator: "=").first.map(String.init) ?? "") { return true } }
            else if a.hasPrefix("-"), a.count > 1 {
                if a.dropFirst().contains(where: { short.contains($0) }) { return true }
            }
        }
        return false
    }

    static func operands(_ args: [String]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        var afterDashes = false
        for (i, a) in args.enumerated() {
            if !afterDashes, a == "--" { afterDashes = true; continue }
            if !afterDashes, a.hasPrefix("-"), a.count > 1 { continue }
            out.append((a, i))
        }
        return out
    }

    static func classifyCommand(_ cmd: ShellCommand, analysis: ShellAnalysis, config: GuardrailConfig) -> [Finding] {
        var out: [Finding] = []
        let args = cmd.args
        let dyn = Array(cmd.dynamic.dropFirst())

        // Redirections.
        for r in cmd.redirects {
            guard let target = r.target else { continue }
            let writes = r.op.contains(">")
            if r.targetIsDynamic {
                out += credentialScan(target, mode: writes ? .write : .read, config: config)
                if writes { out.append(Finding(.exec, "redirect.dynamic", "redirects output to a computed path", clean: .ask, tainted: .askStrict)) }
                continue
            }
            if target == "/dev/null" || target == "/dev/stdout" || target == "/dev/stderr" || target == "/dev/tty" || target.hasPrefix("&") || target.allSatisfy(\.isNumber) || target == "-" { continue }
            out += pathFindings(target, mode: writes ? .write : .read, config: config)
            if writes {
                out.append(Finding(.reversibleWrite, "redirect.write", "writes to \(target)", clean: .ask, tainted: .ask,
                                   checkpointPaths: [ShellAnalyzer.normalize(path: target, cwd: config.cwd, home: config.home)]))
            }
        }

        // Assignment values that point at credentials (`P=~/.ssh/id_rsa; cat $P`).
        for a in cmd.assignments {
            if a.hasPrefix("LD_PRELOAD=") { out.append(Finding(.credential, "shell.ld_preload", "LD_PRELOAD injection", clean: .deny, tainted: .deny)) }
            if let eq = a.firstIndex(of: "=") {
                let value = String(a[a.index(after: eq)...])
                out += pathFindings(value, mode: .read, config: config).filter { $0.clean >= .askStrict }
            }
        }

        guard let program = cmd.program else { return out }
        guard !cmd.programIsDynamic else { return out }   // already flagged unresolved
        guard let name = ShellAnalyzer.recognizedName(of: program) else {
            out.append(Finding(.exec, "exec.path", "runs an executable by path (\(program))", clean: .ask, tainted: .askStrict))
            return out
        }

        // Every argument that looks like a path gets the credential check (even
        // for read-only programs): `cat ~/.ssh/id_rsa`, `grep -r x ~/.aws`.
        let operandList = operands(args)
        let writesTargets: Bool = ["rm", "rmdir", "unlink", "mv", "cp", "touch", "mkdir", "tee", "truncate", "ln", "install", "chmod", "chown", "chgrp", "sed", "shred", "dd", "tar", "unzip", "rsync"].contains(name)
        for (value, idx) in operandList {
            guard idx < dyn.count else { continue }
            if value.contains("="), !value.hasPrefix("="), value.firstIndex(of: "=")! < (value.firstIndex(of: "/") ?? value.endIndex) {
                out += credentialScan(value, mode: name == "dd" ? .write : .read, config: config)
            }
            if dyn[idx] {
                out += credentialScan(value, mode: writesTargets ? .write : .read, config: config)
                if readOrWritePathPrograms.contains(name), value.contains("$") || value.contains("`") || value.contains("<(") || value.contains("{") {
                    out.append(Finding(.exec, "path.dynamic", "\(name) on a path computed at run time", clean: .ask, tainted: .askStrict))
                }
                if !(value.contains("*") || value.contains("?") || value.contains("[")) { continue }
            }
            // Only operands that look like filesystem paths.
            if value.contains("/") || value.hasPrefix(".") || value.hasPrefix("~") || value.contains("*") || PathRules.isCanary(ShellAnalyzer.normalize(path: value, cwd: config.cwd, home: config.home)) || looksLikeSensitiveName(value) {
                let mode: PathMode = writesTargets ? .write : .read
                out += pathFindings(value, mode: mode, config: config)
            }
        }

        // Values glued to options (`-d@file`, `--file=path`, `-o/path`) are not
        // operands but are still paths.
        for a in args where a.hasPrefix("-") && a.count > 2 {
            out += credentialScan(a, mode: .read, config: config)
        }
        // Options whose value is a file the program WRITES.
        out += writtenOptionTargets(name: name, args: args, config: config)

        // Reading devices that never end, or raw memory.
        if !["tee", "dd"].contains(name) {
            for (value, _) in operandList where value.hasPrefix("/dev/") || value.hasPrefix("/proc/") {
                let n = ShellAnalyzer.normalize(path: value, cwd: config.cwd, home: config.home)
                if ["/dev/zero", "/dev/urandom", "/dev/random", "/dev/full", "/dev/stdin", "/dev/tty", "/dev/console"].contains(n) || n.hasPrefix("/dev/fd/") {
                    out.append(Finding(.exec, "exec.endless_device", "reads an endless device", clean: .ask, tainted: .askStrict))
                }
            }
        }

        // Recursive content search or find+exec rooted at a credential-rich tree.
        let recursiveSearch = ["grep", "egrep", "fgrep"].contains(name) && hasFlag(args, short: ["r", "R"], long: ["recursive", "dereference-recursive"])
            || ["rg", "ag", "ack"].contains(name)
            || name == "find" && args.contains(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) })
        if recursiveSearch {
            for (value, idx) in operandList where idx >= 0 {
                let n = ShellAnalyzer.normalize(path: value, cwd: config.cwd, home: config.home)
                let underWorkspace = n == config.cwd || n.hasPrefix(config.cwd + "/")
                if !underWorkspace, PathRules.sensitiveSamples.contains(where: { $0.hasPrefix(n == "/" ? "/" : n + "/") }) || n.hasPrefix("/proc") || n.hasPrefix("/etc") || n.hasPrefix("/root") {
                    out.append(Finding(.credential, "path.broad_search", "searches content under \(n), which holds credentials", clean: .askStrict, tainted: .deny))
                }
            }
        }

        // Privilege.
        if privilege.contains(name) || cmd.wrappers.contains(where: privilege.contains) {
            out.append(Finding(.credential, "exec.privilege", "elevates privileges (\(name))", clean: .askStrict, tainted: .deny))
        }
        if miners.contains(name) { out.append(Finding(.credential, "exec.miner", "cryptocurrency miner", clean: .deny, tainted: .deny)) }
        if hackTools.contains(name) { out.append(Finding(.credential, "exec.offensive_tool", "offensive security tool (\(name))", clean: .askStrict, tainted: .deny)) }
        if systemModifiers.contains(name) || name.hasPrefix("mkfs.") {
            out.append(Finding(.destructive, "destroy.disk", "\(name) can erase disks/partitions", clean: .askStrict, tainted: .deny))
        }

        switch name {
        case "cd", "pushd", "chdir":
            if let dir = operandList.first?.0 {
                let n = ShellAnalyzer.normalize(path: dir, cwd: config.cwd, home: config.home)
                if PathRules.credentialDeny(n + "/x") != nil || PathRules.credentialDeny(n) != nil || PathRules.credentialDeny(n + "/config") != nil || PathRules.credentialDeny(n + "/credentials") != nil || PathRules.credentialDeny(n + "/config.json") != nil || PathRules.credentialDeny(n + "/hosts.yml") != nil {
                    out.append(Finding(.credential, "path.cd_credential", "changes into a credential directory (\(n))", clean: .deny, tainted: .deny))
                }
            }
            out.append(Finding(.exec, "exec.cd", "changes directory", clean: .ask, tainted: .askStrict))

        case "parallel", "systemd-run", "systemd-cat", "gdb", "lldb", "gcore", "perf", "bpftrace":
            out.append(Finding(.credential, "security.system", "\(name) runs commands indirectly or inspects other processes", clean: .askStrict, tainted: .deny))

        case "rm", "rmdir", "unlink":
            out += classifyRemove(name: name, args: args, dyn: dyn, config: config)

        case "dd":
            let of = args.first { $0.hasPrefix("of=") }
            out.append(Finding(.destructive, "destroy.dd", of.map { "dd writes to \($0.dropFirst(3))" } ?? "dd", clean: .askStrict, tainted: .deny))

        case "truncate":
            out.append(Finding(.destructive, "destroy.truncate", "truncates files", clean: .askStrict, tainted: .deny))

        case "chmod", "chown", "chgrp":
            if hasFlag(args, short: ["R"], long: ["recursive"]) {
                out.append(Finding(.destructive, "destroy.chmod_r", "\(name) -R changes many files at once", clean: .askStrict, tainted: .deny))
            }
            if name == "chmod", args.contains(where: { $0 == "777" || $0 == "a+rwx" || $0.range(of: #"[+=][rwxXt]*s"#, options: .regularExpression) != nil || ($0.count == 4 && ["2", "4", "6"].contains($0.first.map(String.init) ?? "")) }) {
                out.append(Finding(.credential, "security.chmod_open", "makes files world-writable or setuid", clean: .askStrict, tainted: .deny))
            }

        case "find":
            if args.contains("-delete") {
                out.append(Finding(.destructive, "destroy.find_delete", "find -delete removes everything it matches", clean: .askStrict, tainted: .deny))
            }
            if args.contains(where: { ["-fprint", "-fprintf", "-fls", "-fprint0"].contains($0) }) {
                out.append(Finding(.reversibleWrite, "write.find_fprint", "find writes results to a file", clean: .ask, tainted: .ask))
            }
            if !args.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls", "-fprint0"].contains($0) }) {
                out.append(Finding(.observe, "read.find", "searches for files", clean: .allow, tainted: .allow))
            }

        case "git":
            out += classifyGit(args: args, dyn: dyn, config: config)

        case "docker", "podman", "nerdctl":
            out += classifyContainerCLI(name: name, args: args)

        case "kubectl", "helm", "terraform", "tofu", "pulumi", "ansible", "ansible-playbook", "aws", "gcloud", "az", "doctl", "heroku", "flyctl", "vercel", "netlify", "wrangler":
            out += classifyCloud(name: name, args: args)

        case "kill", "pkill", "killall":
            let targets = operandList.map(\.0)
            let hard = args.contains("-9") || args.contains("-KILL") || args.contains("-SIGKILL") || args.contains("-s") && args.contains("KILL")
            if name == "kill" && !targets.contains(where: { $0 == "-1" || $0 == "1" || $0 == "0" }) && !(hard && targets.isEmpty) {
                out.append(Finding(.exec, "exec.kill", "signals a process", clean: .ask, tainted: .askStrict))
            } else {
                out.append(Finding(.destructive, "destroy.kill", "\(name) can take down many or critical processes", clean: .askStrict, tainted: .deny))
            }

        case "shutdown", "reboot", "halt", "poweroff", "init", "telinit":
            out.append(Finding(.destructive, "destroy.power", "\(name) stops the machine", clean: .askStrict, tainted: .deny))

        case "systemctl", "service", "launchctl", "rc-service":
            let verbs = Set(operandList.map(\.0))
            if !verbs.isDisjoint(with: ["enable", "mask", "preset", "link", "add", "load", "bootstrap", "install"]) {
                out.append(Finding(.credential, "persist.service", "enables a service (persistence)", clean: .deny, tainted: .deny))
            } else if !verbs.isDisjoint(with: ["stop", "disable", "kill", "reboot", "poweroff", "halt", "isolate", "unload", "remove", "bootout"]) {
                out.append(Finding(.destructive, "destroy.service", "stops or disables a service", clean: .askStrict, tainted: .deny))
            } else if !verbs.isDisjoint(with: ["status", "list-units", "is-active", "is-enabled", "show", "cat", "list"]) {
                out.append(Finding(.observe, "read.service", "inspects services", clean: .allow, tainted: .allow))
            } else {
                out.append(Finding(.exec, "exec.service", "controls a service", clean: .ask, tainted: .askStrict))
            }

        case "crontab", "at", "batch", "anacron":
            if name == "crontab", args.contains("-l") && !args.contains("-r") {
                out.append(Finding(.observe, "read.crontab", "lists cron jobs", clean: .allow, tainted: .allow))
            } else if name == "crontab", args.contains("-r") {
                out.append(Finding(.destructive, "destroy.crontab", "removes all cron jobs", clean: .askStrict, tainted: .deny))
            } else {
                out.append(Finding(.credential, "persist.cron", "schedules a job (persistence)", clean: .deny, tainted: .deny))
            }

        case "iptables", "ip6tables", "nft", "ufw", "firewall-cmd", "pfctl", "setenforce", "aa-teardown", "sysctl":
            if args.contains(where: { ["-L", "-S", "-n", "status", "list", "show", "--list", "-l"].contains($0) }) && !args.contains(where: { ["-F", "-D", "-X", "flush", "delete", "disable", "-w"].contains($0) }) {
                out.append(Finding(.observe, "read.firewall", "inspects firewall/kernel settings", clean: .allow, tainted: .allow))
            } else {
                out.append(Finding(.credential, "security.firewall", "changes firewall / security settings", clean: .deny, tainted: .deny))
            }

        case "ln":
            if hasFlag(args, short: ["s"], long: ["symbolic"]) {
                out.append(Finding(.exec, "exec.symlink", "creates a symbolic link (can point outside the workspace)", clean: .askStrict, tainted: .deny))
            }

        case "mount", "umount", "chroot", "unshare", "nsenter", "capsh", "setcap", "modprobe", "insmod", "rmmod", "swapon", "swapoff":
            out.append(Finding(.credential, "security.system", "\(name) changes system isolation or kernel state", clean: .askStrict, tainted: .deny))

        case "env", "printenv", "declare", "export", "set", "compgen", "typeset", "readonly":
            if name == "env" && !args.contains(where: { !$0.hasPrefix("-") && !$0.contains("=") }) && cmd.wrappers.isEmpty || name == "printenv" || (name == "export" && (args.isEmpty || args.contains(where: { $0.hasPrefix("-") && $0.contains("p") }))) || (name == "readonly" && (args.isEmpty || args.contains("-p"))) || (name == "set" && args.isEmpty) || (name == "declare" && (args.isEmpty || args.allSatisfy { $0.hasPrefix("-") })) || name == "compgen" && (args.contains("-e") || args.contains("-v")) || name == "typeset" && (args.isEmpty || args.allSatisfy { $0.hasPrefix("-") }) {
                out.append(Finding(.credential, "secrets.env_dump", "dumps the environment (may contain secrets)", clean: .askStrict, tainted: .deny))
            }

        case "curl", "wget", "fetch", "aria2c", "axel", "lwp-download", "http", "https", "xh":
            out += classifyDownloader(name: name, args: args, dyn: dyn)

        case "ssh", "scp", "sftp", "rsync", "ftp", "tftp", "mosh", "telnet", "nc", "ncat", "netcat", "socat", "mail", "mailx", "sendmail", "mutt", "msmtp", "swaks":
            if name == "rsync" && !args.contains(where: { $0.contains(":") && !$0.hasPrefix("-") }) {
                out.append(Finding(.reversibleWrite, "write.rsync_local", "local rsync", clean: .ask, tainted: .askStrict))
            } else {
                out.append(Finding(.external, "external.remote", "\(name) talks to a remote machine", clean: .askStrict, tainted: .deny))
            }

        case "command", "builtin":
            // `command -v X` is a lookup. Otherwise `command X` / `builtin X` just run X, which is classified on its own
            // (the analyzer lists the peeled inner command separately), so the wrapper adds no finding of its own.
            let lookup = args.first.map { $0.hasPrefix("-") && ($0.contains("v") || $0.contains("V")) } ?? false
            if lookup {
                out.append(Finding(.observe, "read.command_lookup", "looks up whether a program exists", clean: .allow, tainted: .allow))
            }

        case "gh", "glab", "hub":
            let sub = operandList.first?.0 ?? ""
            // Purely local / informational: version, help, and "am I logged in".
            let second = operandList.dropFirst().first?.0 ?? ""
            let local = args.contains("--version") || args.contains("--help") || args.contains("-h")
                || sub == "version" || sub == "help" || (sub == "auth" && second == "status")
            if local {
                out.append(Finding(.observe, "read.gh_local", "GitHub CLI status or version", clean: .allow, tainted: .allow))
            } else if ["pr", "issue", "release", "repo", "workflow", "gist", "api", "secret", "variable"].contains(sub) {
                let verbs = Set(operandList.map(\.0))
                if !verbs.isDisjoint(with: ["list", "view", "status", "diff", "checks", "download", "get"]) && verbs.isDisjoint(with: ["create", "delete", "merge", "close", "edit", "comment", "set", "upload", "run", "-X"]) && sub != "api" {
                    out.append(Finding(.network, "network.gh_read", "reads from GitHub", clean: .ask, tainted: .askStrict))
                } else {
                    out.append(Finding(.external, "external.gh_write", "changes something on GitHub", clean: .askStrict, tainted: .deny))
                }
            } else {
                out.append(Finding(.external, "external.gh", "GitHub CLI", clean: .askStrict, tainted: .deny))
            }

        case let n where installers.contains(n):
            out += classifyInstaller(name: n, args: args)

        case "python", "python3", "python2", "node", "nodejs", "perl", "ruby", "php", "lua", "tclsh", "deno", "bun":
            out += classifyInterpreter(name: name, args: args)

        case "sh", "bash", "zsh", "dash", "ksh", "fish", "ash":
            out.append(Finding(.exec, "exec.shell", "starts a shell", clean: .ask, tainted: .askStrict))

        case "source", ".", "eval", "exec":
            out.append(Finding(.exec, "exec.\(name)", "\(name) runs code that isn't visible here", clean: .ask, tainted: .askStrict))

        case "sed":
            // GNU sed's `e` / `w` commands and -i can execute or write.
            let script = operandList.first?.0 ?? ""
            if hasFlag(args, short: ["i"], long: ["in-place"]) {
                out.append(Finding(.reversibleWrite, "write.sed_i", "edits files in place", clean: .ask, tainted: .ask,
                                   checkpointPaths: operandList.dropFirst().map { ShellAnalyzer.normalize(path: $0.0, cwd: config.cwd, home: config.home) }))
            } else if script.range(of: #"(^|[;{\s])[ew]\s"#, options: .regularExpression) != nil || script.contains("/e") || script.contains("/w") {
                out.append(Finding(.exec, "exec.sed_e", "sed script can execute or write", clean: .ask, tainted: .askStrict))
            } else {
                out.append(Finding(.observe, "read.sed", "filters text", clean: .allow, tainted: .allow))
            }

        case "awk", "gawk", "mawk":
            let prog = args.joined(separator: " ")
            let risky = prog.contains("system") || prog.contains("ENVIRON") || prog.contains("getline") || prog.contains(">") || prog.contains("|") || args.contains(where: { $0 == "-f" || $0 == "-i" || $0 == "-e" || $0.hasPrefix("--file") })
            out.append(Finding(.exec, "exec.awk", "awk can run commands and write files", clean: risky ? .askStrict : .ask, tainted: .askStrict))

        case "tar", "unzip", "zip", "gzip", "gunzip", "bzip2", "xz", "7z", "cpio", "ar":
            let extracting = hasFlag(args, short: ["x"], long: ["extract", "get"]) || name == "unzip" || name == "gunzip" || name == "7z" && args.first == "x"
            out.append(Finding(extracting ? .reversibleWrite : .exec, "archive.\(name)", extracting ? "extracts files (may overwrite)" : "creates/changes an archive", clean: .ask, tainted: .askStrict))

        case "mv", "cp", "touch", "mkdir", "tee", "install":
            let paths = operandList.map { ShellAnalyzer.normalize(path: $0.0, cwd: config.cwd, home: config.home) }
            out.append(Finding(.reversibleWrite, "write.\(name)", "\(name) changes files", clean: .ask, tainted: .ask,
                               checkpointPaths: name == "mv" || name == "cp" || name == "tee" ? paths : []))

        case "sqlite3", "psql", "mysql", "mariadb", "mongosh", "mongo", "redis-cli", "cockroach", "clickhouse-client":
            let blob = args.joined(separator: " ")
            if blob.range(of: #"\b(drop|truncate|delete\s+from|alter\s+table|flushall|flushdb|shutdown|update\s+\w+\s+set)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                out.append(Finding(.destructive, "destroy.sql", "database statement that destroys or rewrites data", clean: .askStrict, tainted: .deny))
            } else {
                out.append(Finding(.exec, "exec.db", "runs database commands", clean: .ask, tainted: .askStrict))
            }

        case "xargs":
            break   // unwrapped into its own command already

        case "tail", "head", "cat", "less", "more":
            if hasFlag(args, short: ["f", "F"], long: ["follow", "retry"]) || (name == "less" || name == "more") && args.contains(where: { $0.hasPrefix("+") || ["-o", "-O", "-k", "-t", "--log-file", "--lesskey-file"].contains($0) }) {
                out.append(Finding(.exec, "exec.follow", "follows a file indefinitely", clean: .ask, tainted: .ask))
            } else {
                out.append(Finding(.observe, "read.\(name)", "reads files", clean: .allow, tainted: .allow))
            }

        case "history":
            out.append(Finding(.credential, "security.history", "reads shell history", clean: .askStrict, tainted: .deny))

        default:
            if name == "git" { break }
            if readOnlyPrograms.contains(name) {
                out.append(Finding(.observe, "read.\(name)", "read-only command", clean: .allow, tainted: .allow))
            } else if (name.hasPrefix("python") || name.hasPrefix("pip")) {
                out += name.hasPrefix("pip") ? classifyInstaller(name: name, args: args) : classifyInterpreter(name: name, args: args)
            } else {
                out.append(Finding(.exec, "exec.unknown", "runs \(name)", clean: .ask, tainted: .askStrict))
            }
        }

        // A read-only program fed dynamic arguments is not provably read-only.
        if cmd.argsAreDynamic, out.allSatisfy({ $0.effect == .observe }) {
            out.append(Finding(.exec, "args.dynamic", "arguments are computed at run time", clean: .ask, tainted: .askStrict))
        }
        if cmd.viaFindExec {
            out.append(Finding(.exec, "exec.find_exec", "find runs this once per match", clean: .ask, tainted: .askStrict))
        }
        if !cmd.wrappers.isEmpty, cmd.wrappers.contains(where: { ["watch", "nohup", "setsid", "script", "strace", "ltrace", "chroot", "busybox", "flock"].contains($0) }) {
            out.append(Finding(.exec, "exec.wrapper", "runs under a process wrapper", clean: .ask, tainted: .askStrict))
        }
        if name == "sleep", let d = args.first, Double(d).map({ $0 > 60 }) ?? true {
            out.append(Finding(.exec, "exec.long_sleep", "sleeps for a long or unbounded time", clean: .ask, tainted: .askStrict))
        }
        if name == "jq", args.contains(where: { $0.contains("env") || $0.contains("$ENV") || $0.contains("input_filename") && false }) {
            out.append(Finding(.credential, "secrets.env_dump", "jq can read the environment", clean: .askStrict, tainted: .deny))
        }
        if name == "sort" || name == "uniq" || name == "xxd", out.contains(where: { $0.effect != .observe }) == false,
           (name == "sort" && args.contains(where: { $0 == "-o" || $0.hasPrefix("--output") })) || (name != "sort" && operandList.count >= 2) {
            out.append(Finding(.reversibleWrite, "write.\(name)", "writes an output file", clean: .ask, tainted: .askStrict))
        }
        if cmd.viaXargs {
            out.append(Finding(.exec, "exec.xargs", "xargs runs this once per input item", clean: .ask, tainted: .askStrict))
        }
        return out
    }

    static let readOrWritePathPrograms: Set<String> = [
        "cat", "head", "tail", "less", "more", "cp", "mv", "rm", "tar", "base64", "xxd", "od", "strings", "grep", "rg", "scp",
        "rsync", "unzip", "zip", "touch", "mkdir", "tee", "ln", "chmod", "chown", "shred", "truncate", "dd", "hexdump",
        "sed", "awk", "find", "ls", "stat", "file", "wc", "sort", "diff",
    ]

    static func looksLikeSensitiveName(_ value: String) -> Bool {
        let v = value.lowercased()
        return v.hasPrefix(".env") || v.hasSuffix(".pem") || v.hasSuffix(".key") || v.hasPrefix("id_") || v == "credentials" || v == "secrets" || v == ".npmrc" || v == ".netrc" || v.hasSuffix(".p12")
    }

    // MARK: rm

    static func classifyRemove(name: String, args: [String], dyn: [Bool], config: GuardrailConfig) -> [Finding] {
        var out: [Finding] = []
        let recursive = hasFlag(args, short: ["r", "R"], long: ["recursive"]) || name == "rmdir" && false
        let targets = operands(args)
        var wide = recursive
        var paths: [String] = []
        for (value, idx) in targets {
            if idx < dyn.count, dyn[idx] { wide = true; out.append(Finding(.destructive, "destroy.rm_dynamic", "deletes a path computed at run time", clean: .askStrict, tainted: .deny)); continue }
            if value.contains("*") || value.contains("?") || value.contains("[") { wide = true }
            let n = ShellAnalyzer.normalize(path: value, cwd: config.cwd, home: config.home)
            paths.append(n)
            let protected: Set<String> = ["/", config.home, config.cwd, "/home", "/etc", "/usr", "/var", "/bin", "/lib", "/opt", "/root", "/tmp"]
            if protected.contains(n) {
                out.append(Finding(.destructive, "destroy.rm_protected", "deletes a protected directory (\(n))", clean: .deny, tainted: .deny))
            } else if !PathRules.isWritable(n, config: config) {
                out.append(Finding(.destructive, "destroy.rm_outside", "deletes outside the workspace (\(n))", clean: .askStrict, tainted: .deny))
            }
        }
        if wide {
            out.append(Finding(.destructive, "destroy.rm_recursive", recursive ? "recursive delete" : "delete with wildcards",
                               clean: .askStrict, tainted: .deny, checkpointPaths: paths))
        } else if targets.count > 3 {
            out.append(Finding(.destructive, "destroy.rm_many", "deletes \(targets.count) files at once", clean: .askStrict, tainted: .deny, checkpointPaths: paths))
        } else {
            out.append(Finding(.reversibleWrite, "write.rm_file", "deletes files", clean: .ask, tainted: .askStrict, checkpointPaths: paths))
        }
        return out
    }

    // MARK: git

    static func classifyGit(args: [String], dyn: [Bool], config: GuardrailConfig) -> [Finding] {
        let blob = args.joined(separator: " ")
        // Skip global options to find the subcommand.
        var k = 0
        let withValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]
        while k < args.count, args[k].hasPrefix("-") { k += withValue.contains(args[k]) ? 2 : 1 }
        // `-c key=value` injects config only as a global option (before the
        // subcommand), or on `clone`, which writes it into the new repo.
        // After any other subcommand `-c` means something ordinary
        // (`switch -c` creates a branch, `grep -c` counts, `commit -c`
        // reuses a message), so it is not flagged there.
        let global = args.prefix(min(k, args.count))
        let isConfigFlag: (String) -> Bool = { $0.hasPrefix("-c") || $0 == "--config" || $0.hasPrefix("--config=") || $0.hasPrefix("--config-env") }
        let injectsConfig = global.contains(where: isConfigFlag)
            || (k < args.count && args[k] == "clone" && args[(k + 1)...].contains(where: isConfigFlag))
        if injectsConfig || blob.range(of: #"--exec-path|core\.(sshcommand|pager|editor|fsmonitor|hookspath|askpass|gitproxy)|alias\.|diff\.external|filter\.|credential\.helper|protocol\.\S*allow|ext::|--upload-pack|--receive-pack|--exec(=|\s)|\s-O\S*|--open-files-in-pager|--ext-diff|--textconv|\s-x\s"#, options: [.regularExpression, .caseInsensitive]) != nil,
           !blob.hasPrefix("config --get") {
            return [Finding(.credential, "security.git_exec", "git option or config that runs a command or redirects execution", clean: .askStrict, tainted: .deny)]
        }
        if let sub = args.first(where: { !$0.hasPrefix("-") }), ["difftool", "mergetool", "bisect", "submodule", "instaweb", "daemon", "send-email", "archive", "bundle", "svn", "request-pull"].contains(sub) {
            return [Finding(.external, "security.git_exec", "git \(sub) can run commands or contact remotes", clean: .askStrict, tainted: .deny)]
        }
        guard k < args.count else { return [Finding(.observe, "read.git", "git", clean: .allow, tainted: .allow)] }
        let sub = args[k]
        let rest = Array(args[(k + 1)...])
        let flagSet = Set(rest)

        switch sub {
        case _ where gitReadOnly.contains(sub):
            if rest.contains(where: { $0.hasPrefix("--output") || $0 == "-o" }) {
                return [Finding(.credential, "write.git_output", "git writes its output to a file", clean: .askStrict, tainted: .deny)]
            }
            return [Finding(.observe, "read.git_\(sub)", "reads repository state", clean: .allow, tainted: .allow)]
        case "branch":
            if rest.isEmpty || rest.allSatisfy({ ["-a", "-r", "-v", "-vv", "--list", "--all", "--remotes", "--show-current", "--verbose"].contains($0) }) {
                return [Finding(.observe, "read.git_branch", "lists branches", clean: .allow, tainted: .allow)]
            }
            // `-c`/`--copy` is left out on purpose: a plain copy refuses to
            // overwrite an existing branch, unlike `-C` (force-copy).
            if flagSet.contains("-D") || flagSet.contains("--delete") || flagSet.contains("-d") || flagSet.contains("-M") || flagSet.contains("-f") || flagSet.contains("--force") || flagSet.contains("-m") || flagSet.contains("-C") {
                return [Finding(.destructive, "destroy.git_branch", "deletes, renames or force-copies a branch", clean: .askStrict, tainted: .deny)]
            }
            return [Finding(.exec, "exec.git_branch", "creates or copies a branch", clean: .ask, tainted: .askStrict)]
        case "remote":
            return rest.isEmpty || rest.allSatisfy({ $0.hasPrefix("-") }) || rest.first == "show" || rest.first == "get-url"
                ? [Finding(.observe, "read.git_remote", "lists remotes", clean: .allow, tainted: .allow)]
                : [Finding(.external, "external.git_remote", "changes remotes", clean: .askStrict, tainted: .deny)]
        case "config":
            if flagSet.contains("--get") || flagSet.contains("--list") || flagSet.contains("-l") {
                return [Finding(.exec, "exec.git_config_read", "reads git config (may expose credentials)", clean: .ask, tainted: .askStrict)]
            }
            return [Finding(.credential, "security.git_config", "changes git configuration", clean: .askStrict, tainted: .deny)]
        case "push":
            let force = rest.contains(where: { $0 == "-f" || $0.hasPrefix("--force") || $0 == "--mirror" || $0 == "--delete" || $0 == "-d" || $0.hasPrefix("+") || $0.hasPrefix(":") })
            return force
                ? [Finding(.destructive, "destroy.git_push_force", "force-push / delete remote ref rewrites shared history", clean: .askStrict, tainted: .deny)]
                : [Finding(.external, "external.git_push", "publishes commits to a remote", clean: .askStrict, tainted: .deny)]
        case "reset":
            return flagSet.contains("--hard") || flagSet.contains("--merge") || flagSet.contains("--keep")
                ? [Finding(.destructive, "destroy.git_reset", "git reset --hard discards work", clean: .askStrict, tainted: .deny)]
                : [Finding(.exec, "exec.git_reset", "moves HEAD / unstages", clean: .ask, tainted: .askStrict)]
        case "clean":
            return rest.contains(where: { $0.hasPrefix("-") && $0.contains("f") || $0 == "--force" })
                ? [Finding(.destructive, "destroy.git_clean", "git clean -f deletes untracked files", clean: .askStrict, tainted: .deny)]
                : [Finding(.exec, "exec.git_clean", "git clean (dry run)", clean: .ask, tainted: .askStrict)]
        case "checkout", "restore", "switch":
            if rest.contains(".") || rest.contains("--") || rest.contains("-f") || rest.contains("--force") || rest.contains("--discard-changes") || rest.contains("-C") {
                return [Finding(.destructive, "destroy.git_discard", "discards uncommitted changes", clean: .askStrict, tainted: .deny)]
            }
            return [Finding(.exec, "exec.git_\(sub)", "switches branch / restores files", clean: .ask, tainted: .askStrict)]
        case "stash":
            if rest.first == "drop" || rest.first == "clear" {
                return [Finding(.destructive, "destroy.git_stash", "drops stashed work", clean: .askStrict, tainted: .deny)]
            }
            return [Finding(.exec, "exec.git_stash", "stashes changes", clean: .ask, tainted: .askStrict)]
        case "reflog", "gc", "prune", "filter-branch", "filter-repo", "replace", "update-ref", "worktree":
            if sub == "worktree" && !flagSet.contains("remove") && !flagSet.contains("prune") {
                return [Finding(.exec, "exec.git_worktree", "git worktree", clean: .ask, tainted: .askStrict)]
            }
            return [Finding(.destructive, "destroy.git_\(sub)", "rewrites or deletes repository history/objects", clean: .askStrict, tainted: .deny)]
        case "tag":
            if flagSet.contains("-d") || flagSet.contains("--delete") || flagSet.contains("-f") {
                return [Finding(.destructive, "destroy.git_tag", "deletes or moves a tag", clean: .askStrict, tainted: .deny)]
            }
            return rest.isEmpty || flagSet.contains("-l") ? [Finding(.observe, "read.git_tag", "lists tags", clean: .allow, tainted: .allow)] : [Finding(.exec, "exec.git_tag", "creates a tag", clean: .ask, tainted: .askStrict)]
        case "clone", "fetch", "pull", "submodule", "lfs", "remote-add":
            return [Finding(.network, "network.git_\(sub)", "downloads code from a remote (untrusted content)", clean: .ask, tainted: .askStrict)]
        case "rebase", "commit", "merge", "cherry-pick", "revert", "am", "apply", "add", "rm", "mv", "init", "notes":
            let rewrite = sub == "rebase" || (sub == "commit" && flagSet.contains("--amend")) || sub == "rm"
            return [Finding(rewrite ? .destructive : .reversibleWrite, "write.git_\(sub)", rewrite ? "rewrites local history / removes tracked files" : "changes the repository",
                            clean: rewrite ? .askStrict : .ask, tainted: rewrite ? .deny : .askStrict)]
        default:
            return [Finding(.exec, "exec.git_\(sub)", "git \(sub)", clean: .ask, tainted: .askStrict)]
        }
    }

    // MARK: containers / cloud

    static func classifyContainerCLI(name: String, args: [String]) -> [Finding] {
        let verbs = Set(operands(args).map(\.0))
        if !verbs.isDisjoint(with: ["ps", "images", "inspect", "logs", "version", "info", "stats", "top", "diff", "history", "ls", "list"]) && verbs.isDisjoint(with: ["rm", "rmi", "prune", "kill", "stop"]) {
            return [Finding(.observe, "read.container", "inspects containers", clean: .ask, tainted: .ask)]
        }
        if !verbs.isDisjoint(with: ["rm", "rmi", "prune", "kill", "stop", "down", "destroy", "volume", "network"]) {
            return [Finding(.destructive, "destroy.container", "removes containers, images or volumes", clean: .askStrict, tainted: .deny)]
        }
        if !verbs.isDisjoint(with: ["push", "login", "tag"]) {
            return [Finding(.external, "external.container_push", "publishes or authenticates to a registry", clean: .askStrict, tainted: .deny)]
        }
        return [Finding(.credential, "security.container_run", "starts a container (can mount the host / escape isolation)", clean: .askStrict, tainted: .deny)]
    }

    static func classifyCloud(name: String, args: [String]) -> [Finding] {
        let words = args.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        let blob = words.joined(separator: " ")
        if blob.range(of: #"\b(delete|destroy|terminate|remove|rm|purge|drop|uninstall|teardown|decommission|detach|revoke|reset|wipe|truncate|rollback)\b"#, options: .regularExpression) != nil
            || args.contains("-auto-approve") || args.contains("--auto-approve") || args.contains("--force") {
            return [Finding(.destructive, "destroy.cloud", "\(name) command that deletes or rewrites infrastructure", clean: .askStrict, tainted: .deny)]
        }
        if blob.range(of: #"\b(get|list|describe|show|status|plan|diff|whoami|version|view|logs|ls)\b"#, options: .regularExpression) != nil {
            return [Finding(.network, "network.cloud_read", "reads from \(name)", clean: .ask, tainted: .askStrict)]
        }
        return [Finding(.external, "external.cloud", "\(name) changes remote infrastructure", clean: .askStrict, tainted: .deny)]
    }

    // MARK: network downloaders / installers / interpreters

    static func classifyDownloader(name: String, args: [String], dyn: [Bool]) -> [Finding] {
        var out: [Finding] = []
        let uploadOptions: Set<String> = ["-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "--post-data", "--post-file", "--body-data", "--body-file", "--json"]
        let uploads = args.contains(where: { a in
            let key = a.hasPrefix("--") ? String(a.split(separator: "=", maxSplits: 1).first ?? "") : a
            return uploadOptions.contains(key) || a.hasPrefix("--data") || a.hasPrefix("--form")
        }) || args.contains("-X") && args.contains(where: { ["POST", "PUT", "PATCH", "DELETE"].contains($0.uppercased()) })
            || args.contains(where: { $0.uppercased().hasPrefix("--REQUEST=") && !$0.uppercased().hasSuffix("GET") })
        if uploads {
            out.append(Finding(.external, "external.upload", "\(name) sends data to a remote server", clean: .askStrict, tainted: .deny))
        } else {
            out.append(Finding(.network, "network.download", "downloads from the network (untrusted content)", clean: .ask, tainted: .askStrict))
        }
        for a in args where !a.hasPrefix("-") || a.hasPrefix("--url=") {
            let candidate = a.hasPrefix("--url=") ? String(a.dropFirst(6)) : a
            if candidate.contains("://") { out += urlFindings(candidate) }
            else if looksLikeHostArg(candidate) { out += urlFindings("http://" + candidate) }
        }
        if let i = args.firstIndex(of: "--url"), i + 1 < args.count { out += urlFindings(args[i + 1].contains("://") ? args[i + 1] : "http://" + args[i + 1]) }
        if args.contains(where: { ["-K", "--config", "--netrc", "-n", "--proxy", "-x", "--resolve", "--connect-to", "-i", "--input-file", "-e", "--execute", "--unix-socket", "--next", "-m", "--mirror", "-r", "--recursive"].contains($0) }) {
            out.append(Finding(.external, "network.options", "options that change where or how the request is sent", clean: .askStrict, tainted: .deny))
        }
        if dyn.contains(true) {
            out.append(Finding(.network, "network.dynamic_url", "URL or options computed at run time", clean: .askStrict, tainted: .deny))
        }
        return out
    }

    static func classifyInstaller(name: String, args: [String]) -> [Finding] {
        // `dpkg -l/-L/-s/-S/-V` only query the package database.
        if name == "dpkg" {
            let queries: Set<String> = ["-l", "-L", "-s", "-S", "-V", "-p", "--list", "--listfiles", "--status", "--search", "--verify", "--print-avail", "--get-selections", "--version"]
            let modifying: Set<String> = ["-i", "-r", "-P", "--install", "--remove", "--purge", "--unpack", "--configure", "--force-all", "-x", "--extract"]
            if args.contains(where: { queries.contains($0) }), !args.contains(where: { modifying.contains($0) }) {
                return [Finding(.observe, "read.packages", "queries installed packages", clean: .allow, tainted: .allow)]
            }
        }
        let verbs = Set(operands(args).map { $0.0.lowercased() })
        if !verbs.isDisjoint(with: ["uninstall", "remove", "purge", "autoremove", "rm", "unpublish", "deprecate"]) {
            return [Finding(.destructive, "destroy.uninstall", "uninstalls packages", clean: .askStrict, tainted: .deny)]
        }
        if !verbs.isDisjoint(with: ["publish", "upload", "push", "login", "adduser", "token", "owner"]) {
            return [Finding(.external, "external.publish", "publishes or authenticates to a package registry", clean: .askStrict, tainted: .deny)]
        }
        if !verbs.isDisjoint(with: ["list", "ls", "show", "freeze", "search", "info", "view", "outdated", "--version", "version"]) {
            return [Finding(.observe, "read.packages", "lists packages", clean: .ask, tainted: .ask)]
        }
        return [Finding(.network, "supply_chain.install", "installs third-party code (\(name))", clean: .ask, tainted: .askStrict)]
    }

    static let dangerousCodeMarkers: [String] = [
        "os.system", "subprocess", "shutil.rmtree", "os.remove", "os.unlink", "os.rmdir", "os.removedirs", "pathlib", "socket", "requests.post",
        "urllib.request", "http.client", "ftplib", "smtplib", "ctypes", "eval(", "exec(", "__import__", "child_process", "fs.rm", "fs.unlink",
        "rmSync", "execSync", "spawn", "net.connect", "fetch(", "XMLHttpRequest", "system(", "popen", "open3", "File.delete", "FileUtils.rm",
    ]

    static func classifyInterpreter(name: String, args: [String]) -> [Finding] {
        let blob = args.joined(separator: " ")
        let inlineFlags: Set<Character> = name.hasPrefix("python") ? ["c"] : ["e", "E", "r", "p", "c"]
        let inline = args.contains(where: { a in
            if a == "--eval" || a == "--print" || a.hasPrefix("--eval=") || a.hasPrefix("--print=") { return true }
            return a.hasPrefix("-") && !a.hasPrefix("--") && a.dropFirst().contains(where: { inlineFlags.contains($0) })
        })
        let inPlace = name != "python" && args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("i") }) && name == "perl" || name == "ruby" && args.contains("-i")
        if inPlace {
            return [Finding(.exec, "exec.interpreter_dangerous", "\(name) edits files in place", clean: .askStrict, tainted: .deny)]
        }
        if args.contains(where: { ["-r", "--require", "--import", "--loader", "--experimental-loader", "--inspect", "--inspect-brk", "-x", "-S", "-d"].contains($0) }) && !name.hasPrefix("python") && name != "ruby" || (name == "ruby" && args.contains(where: { $0.hasPrefix("-r") && $0.count > 2 })) {
            return [Finding(.exec, "exec.interpreter_dangerous", "\(name) preloads or attaches code", clean: .askStrict, tainted: .deny)]
        }
        if name.hasPrefix("python"), let m = args.firstIndex(of: "-m"), m + 1 < args.count {
            let mod = args[m + 1]
            if ["pip"].contains(mod) { return classifyInstaller(name: "pip", args: Array(args[(m + 2)...])) }
            if !["http.server", "venv", "json.tool", "unittest", "pytest", "py_compile"].contains(mod) || mod == "http.server" {
                return [Finding(.external, "exec.python_module", "runs python -m \(mod)", clean: .askStrict, tainted: .deny)]
            }
        }
        let extraMarkers = ["environ", "getenv", "process.env", "ENV[", "$ENV", "%ENV", "ENVIRON", "importlib", "getattr", "compile(", "open(", "File.read", "ENV", "readFile", "unlink", "rmtree", "remove", "system", "exec", "popen", "qx", "`", "%x", "Deno.", "Bun.", "require(", "import(", "fopen", "file_put_contents", "file_get_contents", "passthru", "shell_exec", "os.", "io.", "glob", "Path("]
        if inline, let marker = (dangerousCodeMarkers + extraMarkers).first(where: { blob.contains($0) }) {
            return [Finding(.exec, "exec.interpreter_dangerous", "inline \(name) code uses \(marker)", clean: .askStrict, tainted: .deny)]
        }
        return [Finding(.exec, "exec.interpreter", inline ? "runs inline \(name) code" : "runs a \(name) script", clean: .ask, tainted: .askStrict)]
    }
}
