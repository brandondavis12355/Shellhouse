import Foundation
import AgentCore

/// How often each skill has been invoked via a `/command` (see
/// `Bot.matchSlashCommand`/`expandSlashCommand`) — global across every bot,
/// in `UserDefaults` since it's just small counters, not data that needs
/// its own file. Backs the suggestion list shown above the input field the
/// moment you type `/`.
enum SlashCommandUsage {
    private static let key = "slashCommandUsageCounts"

    static func recordUse(_ skillID: String) {
        var counts = allCounts()
        counts[skillID, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }

    private static func allCounts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    /// Most-used first, then padded out with never-used skills (in
    /// whatever order `skills` was already given — `availableSkills` comes
    /// pre-sorted by name) so a bot with no usage history yet still shows
    /// a useful default set rather than an empty list.
    static func suggestions(from skills: [Skill], limit: Int) -> [Skill] {
        let counts = allCounts()
        let used = skills
            .filter { (counts[$0.id] ?? 0) > 0 }
            .sorted { a, b in
                let countA = counts[a.id] ?? 0
                let countB = counts[b.id] ?? 0
                return countA != countB ? countA > countB : a.id < b.id
            }
        guard used.count < limit else { return Array(used.prefix(limit)) }

        let unused = skills.filter { (counts[$0.id] ?? 0) == 0 }
        return used + Array(unused.prefix(limit - used.count))
    }
}
