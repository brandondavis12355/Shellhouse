import Foundation

/// Brings the repositories on a bot's machine up to date before it starts coding work, so it never edits (or reviews)
/// a stale checkout. Always `git fetch`; then fast-forwards a branch only when that cannot lose anything: no local
/// commits ahead and no modified tracked files. Anything else is reported, not touched, and the bot is told to deal
/// with it before editing. Never runs a merge, rebase or reset.
public enum CheckoutSync {
    /// Shell run on the bot's machine. One line per repository directly under `root`.
    public static func script(root: String = "/workspace") -> String {
        let r = shellQuote(root)
        return """
        cd \(r) 2>/dev/null || exit 0
        t=""; command -v timeout >/dev/null 2>&1 && t="timeout 25"
        for d in */.git; do
          [ -e "$d" ] || continue
          r="${d%/.git}"
          if ! $t git -C "$r" fetch --all --prune --quiet >/dev/null 2>&1; then echo "$r: FETCH FAILED"; continue; fi
          b=$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null)
          up=$(git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || { echo "$r: on $b, no upstream branch"; continue; }
          behind=$(git -C "$r" rev-list --count 'HEAD..@{u}' 2>/dev/null)
          ahead=$(git -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null)
          if [ "$behind" = 0 ]; then echo "$r: on $b, up to date with $up"; continue; fi
          dirty=$(git -C "$r" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
          if [ "$ahead" = 0 ] && [ "$dirty" = 0 ]; then
            if git -C "$r" merge --ff-only --quiet '@{u}' >/dev/null 2>&1; then echo "$r: on $b, fast-forwarded $behind commit(s) from $up"
            else echo "$r: on $b, BEHIND $up by $behind (fast-forward failed)"; fi
          else
            echo "$r: on $b, BEHIND $up by $behind (ahead $ahead, $dirty modified file(s)): not changed"
          fi
        done
        """
    }

    /// What the bot should be told, or nil when every repository was already current (nothing to act on).
    public static func note(forReport report: String) -> String? {
        let lines = report.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let changed = lines.filter { $0.contains("fast-forwarded") || $0.contains("BEHIND") || $0.contains("FETCH FAILED") || $0.contains("no upstream") }
        guard !changed.isEmpty else { return nil }
        return "[checkouts] Before coding, your repositories were fetched and brought up to date where that was safe:\n"
            + changed.map { "- \($0)" }.joined(separator: "\n")
            + "\nWork from this state. For a line that says BEHIND, FETCH FAILED or no upstream, sort that out first "
            + "(commit or stash your changes, then `git pull --rebase`, or set the upstream) before you edit anything."
    }
}
