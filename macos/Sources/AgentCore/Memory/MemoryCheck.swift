import Foundation

/// A note that names a checkable fact can carry the command that proved it. The command is re-run when the note is
/// recalled, so a note is believed for what is true now, not for what was true when it was written. Because a stored
/// command is executed later, only a small read-only shape is accepted, and only one that visibly passed in the run
/// that wrote the note (docs/HARNESS-REDESIGN.md 3.4a, "Verify before relying").
public enum MemoryCheck {
    public static let maxLength = 200
    /// Notes whose last pass is newer than this are not checked again.
    public static let recheckAfter: TimeInterval = 600
    public static let maxPerRecall = 3

    private static let forbidden = CharacterSet(charactersIn: ";|<>$`\\\n\r(){}!*?~#")
    private static let testFlags: Set<String> = ["-f", "-d", "-e", "-r", "-x", "-s", "-L"]
    private static let grepFlags: Set<String> = ["-q", "-F", "-i", "-E", "-r", "-w"]
    private static let lsFlags: Set<String> = ["-l", "-a", "-d", "-1"]
    private static let gitArgs: Set<String> = ["--is-inside-work-tree", "--verify", "--git-dir", "--show-toplevel", "-q", "--abbrev-ref"]

    /// Read-only commands chained only with `&&`: `test`, `grep -q`, `command -v`, `git rev-parse`, `ls`. No pipes,
    /// redirects, substitution, globs or `;`. Only the exit code is ever read.
    public static func isAllowed(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, c.count <= maxLength, c.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }
        let segments = c.components(separatedBy: " && ")
        guard segments.count <= 3 else { return false }
        return segments.allSatisfy(segmentAllowed)
    }

    private static func segmentAllowed(_ segment: String) -> Bool {
        guard !segment.contains("&") else { return false }
        let t = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = t.first else { return false }
        let rest = Array(t.dropFirst())
        switch first {
        case "test":
            return rest.count == 2 && testFlags.contains(rest[0]) && !rest[1].hasPrefix("-")
        case "grep":
            let flags = rest.filter { $0.hasPrefix("-") }, plain = rest.filter { !$0.hasPrefix("-") }
            return flags.contains("-q") && flags.allSatisfy(grepFlags.contains) && plain.count >= 2
        case "command":
            return rest.count == 2 && rest[0] == "-v" && !rest[1].hasPrefix("-")
        case "git":
            return rest.first == "rev-parse" && rest.dropFirst().allSatisfy { !$0.hasPrefix("-") || gitArgs.contains($0) }
        case "ls":
            return rest.filter { $0.hasPrefix("-") }.allSatisfy(lsFlags.contains) && !rest.filter { !$0.hasPrefix("-") }.isEmpty
        default:
            return false
        }
    }

    /// Did this run already run `command` and see it exit 0? Read from the prompt as the model saw it, so a check
    /// the model never ran, or ran and saw fail, is not proven.
    public static func wasProven(_ command: String, in messages: [ChatMessage]) -> Bool {
        let wanted = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = 0
        while index < messages.count {
            defer { index += 1 }
            let message = messages[index]
            guard message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty else { continue }
            var results: [ChatMessage] = []
            var next = index + 1
            while next < messages.count, messages[next].role == .tool { results.append(messages[next]); next += 1 }
            for (i, call) in calls.enumerated() where call.name == "run_shell" && i < results.count {
                guard call.arguments["command"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted else { continue }
                if results[i].content.contains("\"exit_code\":0") { return true }
            }
        }
        return false
    }

    /// Re-runs the checks of recalled notes: at most `maxPerRecall`, each only if it hasn't passed lately.
    /// `exec` returns whether the command exited 0, or nil when it could not be run (VM down, timeout): no verdict.
    public static func recheck(_ entries: [MemoryEntry], now: Date = Date(),
                               exec: (String) async -> Bool?) async -> [(id: String, passed: Bool)] {
        var verdicts: [(id: String, passed: Bool)] = []
        for entry in entries where entry.isCheckDue(now: now) {
            if verdicts.count >= maxPerRecall { break }
            guard let command = entry.check, let passed = await exec(command) else { continue }
            verdicts.append((entry.id, passed))
        }
        return verdicts
    }
}

public extension MemoryEntry {
    /// A check the note carries, that may be run (trusted enough, allowed shape) and hasn't passed lately.
    func isCheckDue(now: Date = Date()) -> Bool {
        guard let check, trust >= .selfNote, MemoryCheck.isAllowed(check) else { return false }
        if let verifiedAt, now.timeIntervalSince(verifiedAt) < MemoryCheck.recheckAfter { return false }
        return true
    }
}
