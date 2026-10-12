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

    public static let hint = "This failed because it needs credentials, not because of a typo: retrying it, or trying "
        + "ssh instead, will fail the same way. Call request_credentials once (e.g. a GITHUB_TOKEN field, labelled "
        + "\"GitHub personal access token\") to have your user enter it securely, then retry with "
        + "run_shell(use_secrets: [\"GITHUB_TOKEN\"]), e.g. `gh repo clone owner/repo /workspace/repo`. "
        + "If the request is cancelled, stop and tell your user what you need."
}
