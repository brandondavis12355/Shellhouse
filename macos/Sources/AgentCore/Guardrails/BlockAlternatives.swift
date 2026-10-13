import Foundation

/// What a bot can do instead when an action is blocked, so it acts on the block rather than stopping.
public enum BlockAlternatives {
    /// First matching rule wins. Kept short: one concrete, allowed route.
    static let byRule: [(prefix: String, untrusted: String?, normal: String)] = [
        ("url.secret_in_url", nil, "use a plain https://github.com/ URL with use_secrets: [\"GITHUB_TOKEN\"], after `gh auth setup-git` once."),
        ("shell.use_secrets", "secrets can't be used after reading untrusted content in this run; finish the parts that don't need them and ask your user to rerun the step that does.", "use only GITHUB_TOKEN with plain git/gh commands, or ask your user."),
        ("external.git_push_main", "push to a new branch (`git push origin <your-branch>`) and ask your user to merge it.", "push to a new branch (`git push origin <your-branch>`) and ask your user to merge it, or ask them to approve the push to main."),
        ("external.git_push", "commit locally and ask your user to push; pushing isn't allowed after reading untrusted content.", "push to your own branch."),
        ("destroy.git_push_force", nil, "push to a new branch instead of rewriting history."),
        ("destroy.git_reset", nil, "use `git stash` or a new branch to set work aside instead of discarding it."),
        ("destroy.rm_outside", nil, "work inside /workspace; delete only files you created there."),
        ("destroy.rm_protected", nil, "delete the specific files you mean, not a whole top-level directory."),
        ("destroy.rm", nil, "delete specific paths inside /workspace with a plain `rm -r <path>` (no wildcards, no .git), one command at a time."),
        ("destroy", nil, "choose a reversible change (move to a folder under /workspace, or a new branch) instead."),
        ("exec.privilege", nil, "for packages use `sudo apt-get install -y <name>`; otherwise install into your home (pip --user, a venv, npm in the project)."),
        ("external.remote", nil, "reach GitHub over HTTPS with gh/git; for other hosts, ask your user."),
        ("external.gh", nil, "for repos use `gh repo clone`/`gh pr view`; for changes on GitHub (PRs, issues), ask your user or push a branch."),
        ("external.upload", nil, "save the result in /workspace and tell your user where it is, instead of uploading it."),
        ("shell.remote_exec", nil, "download the script to a file, read it, then run the file if it's safe."),
        ("shell.fetch_then_exec", nil, "download first in one command, read what you got, then run it in a separate command."),
        ("shell.decode_exec", nil, "decode to a file and read it before running anything."),
        ("shell.opaque", nil, "write the code to a file under /workspace and run that file, so it can be checked."),
        ("shell.env_injection", nil, "pass options as command-line flags instead of setting that environment variable."),
        ("security.git_config", nil, "pass settings for one command with flags rather than changing git config."),
        ("path.credential", nil, "leave credential files alone; if you need access, use request_credentials or request_login."),
        ("path.persistence", nil, "keep changes inside /workspace instead of startup files."),
        ("url.private", nil, "use the service's public address, or ask your user for access."),
        ("network.dynamic_url", nil, "write the URL out literally so it can be checked."),
        ("tool.message_bot", nil, "say what you need from that bot in your reply, or @mention it in the group."),
        ("tool.post_to_group", nil, "put the message in your reply to your user instead."),
    ]

    public static func suggestion(for rules: [String], tainted: Bool) -> String? {
        for entry in byRule where rules.contains(where: { $0.hasPrefix(entry.prefix) }) {
            return tainted ? (entry.untrusted ?? entry.normal) : entry.normal
        }
        return nil
    }
}
