import Foundation

/// Recognizes a command that failed because it had no credentials (git over HTTPS or SSH, gh, curl
/// with a 401), so the bot is told to ask for them instead of retrying the same command.
public enum AuthFailure {
    static let patterns = [
        "could not read Username for",
        "could not read Password for",
        "Authentication failed for",
        "Permission denied (publickey",
        "Host key verification failed",
        "gh auth login",
        "HTTP 401",
        "401 Unauthorized",
    ]

    public static func matches(_ output: String) -> Bool {
        patterns.contains { output.contains($0) }
    }

    public static let hint = "This failed because it needs GitHub credentials, not because of a typo: retrying it as is, or "
        + "trying ssh, fails the same way. If a GITHUB_TOKEN is already saved, re-run the same command with "
        + "run_shell(use_secrets: [\"GITHUB_TOKEN\"]). Only if none is saved, call request_credentials once for a GITHUB_TOKEN "
        + "(\"GitHub personal access token\"). If that request is cancelled, stop and tell your user what you need."
}
