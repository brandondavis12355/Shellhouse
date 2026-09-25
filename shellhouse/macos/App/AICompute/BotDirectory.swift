import Foundation

/// Lets every bot discover its siblings — who exists, and (via `tagline`)
/// what each one handles — and actually deliver a message to one of them.
/// One instance, shared across every `Bot` (injected at creation, the same
/// way `RunShellPermissions` already is), owned by `ContentView` — only it
/// has the live `bots` array this needs to read.
@MainActor
final class BotDirectory {
    /// The sidebar's bot list, as of the last `sync(_:)` call. A closure
    /// (`() -> [Bot]`) capturing `ContentView`'s `@State private var bots`
    /// was tried first — in theory a closure over `@State` should always
    /// read the live current value, but in practice it was observed to go
    /// stale (confirmed via debug counters: correct immediately after
    /// assignment, empty on every later call from a re-render or a
    /// different view). Rather than chase that further, `ContentView` now
    /// calls `sync(bots)` explicitly, synchronously, right after every
    /// mutation — a plain passed-by-value array has no capture semantics
    /// to get wrong.
    private var bots: [Bot] = []

    func sync(_ bots: [Bot]) {
        self.bots = bots
    }

    func allBots() -> [Bot] { bots }

    /// Same explicit-sync shape as `bots`/`sync(_:)` — see that doc
    /// comment for why this isn't a closure over `ContentView`'s
    /// `@State private var groupChats`. Lets a routine target a group
    /// (`Bot.fireRoutine`) and, in principle, any future tool that needs
    /// to look up an existing group by name.
    private var groups: [GroupChatSession] = []

    func syncGroups(_ groups: [GroupChatSession]) {
        self.groups = groups
    }

    func allGroups() -> [GroupChatSession] { groups }

    func group(named name: String) -> GroupChatSession? {
        groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func group(id: String) -> GroupChatSession? {
        groups.first { $0.id == id }
    }

    /// Set once by `ContentView` — creates a brand-new bot immediately (no
    /// confirmation sheet), appends it to the sidebar, and boots its own
    /// sandbox — for the `create_bot` tool. `nil` only if this was somehow
    /// never wired up (never true in practice; `ContentView` sets it
    /// before any bot's runtime can start).
    var createBot: (_ name: String, _ tagline: String) -> Bot? = { _, _ in nil }

    /// Set once by `ContentView` — adds `bot` as a member of the named
    /// group chat (case-insensitive match), for the `add_bot_to_group`
    /// tool. `false` if no group has that name, or it's already at
    /// `GroupChatSession.maxMembers`.
    var addBotToGroup: (_ bot: Bot, _ groupName: String) -> Bool = { _, _ in false }

    /// The `list_bots` tool's own view: name plus role. `tagline` doubles
    /// as that role description — the same one shown next to a bot's name
    /// in the sidebar — reading as "General-purpose" when empty rather
    /// than blank.
    func directory(excluding excludedID: String) -> [(name: String, role: String)] {
        allBots()
            .filter { $0.id != excludedID }
            .map { (name: $0.name, role: $0.tagline.isEmpty ? "General-purpose" : $0.tagline) }
    }

    /// Case-insensitive match on name — what a delegating bot actually
    /// names in a `message_bot` call — falling back to id for robustness.
    func bot(named name: String, excluding excludedID: String) -> Bot? {
        allBots().first {
            $0.id != excludedID
                && ($0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame)
        }
    }
}
