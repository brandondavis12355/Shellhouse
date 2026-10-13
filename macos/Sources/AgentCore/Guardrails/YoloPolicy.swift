import Foundation

/// What YOLO mode still refuses to wave through: actions that look like credential theft, data
/// exfiltration, hiding tracks or switching off controls. Everything else runs without asking.
public enum YoloPolicy {
    /// Always suspicious: reading or hunting for keys and credentials, dumping secrets, weakening security,
    /// injecting into other programs, executing fetched or decoded code, odd URLs, attack tools.
    static let maliciousPrefixes = [
        "path.credential", "path.broad_search", "path.persistence", "path.canary", "path.malformed",
        "secrets.", "security.", "shell.env_injection", "shell.ld_preload", "shell.remote_exec", "shell.decode_exec",
        "shell.fetch_then_exec", "shell.cover_tracks", "url.metadata", "url.userinfo", "url.secret_in_url",
        "network.dynamic_url", "exec.offensive_tool", "exec.miner", "destroy.disk", "destroy.rm_protected", "write.git_output",
    ]

    /// Suspicious once the run has read untrusted content: sending data out, using non-GitHub secrets,
    /// reaching private network addresses.
    static let maliciousWhenUntrusted = ["external.upload", "shell.use_secrets", "url.private", "network.options"]

    /// Under `security.` but routine: setting your git name, chmod on your own files, gh's credential helper.
    static let routineSecurityRules: Set<String> = ["security.git_config", "security.chmod_open", "security.gh_setup_git"]

    public static func looksMalicious(_ finding: Finding, untrusted: Bool) -> Bool {
        if finding.tripwire { return true }
        if routineSecurityRules.contains(finding.rule) { return false }
        if maliciousPrefixes.contains(where: { finding.rule.hasPrefix($0) }) { return true }
        if untrusted, maliciousWhenUntrusted.contains(where: { finding.rule == $0 }) { return true }
        return false
    }
}
