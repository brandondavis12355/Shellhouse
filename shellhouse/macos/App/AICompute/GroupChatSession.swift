import Foundation
import Observation

/// A named multi-bot group chat — up to 6 member bots, orchestrated
/// speaking (each decides for itself whether to respond, per turn, unless
/// @mentioned — see `Bot.respondInGroup`). Deliberately its own type
/// rather than a variant of `Bot`: a group has no sandbox or model of its
/// own to run — every action a member takes while responding here still
/// runs against THAT bot's own persistent sandbox, same as a delegation.
@MainActor
@Observable
final class GroupChatSession: Identifiable {
    static let maxMembers = 6

    let id: String
    var name: String
    var memberBotIDs: [String]
    var displayMessages: [GroupMessage] = []
    var input = ""
    var isBusy = false
    var status = ""
    /// Set/cleared alongside `status` during `runTurn` — which member is
    /// actually generating right now, if any, so `GroupChatDetailView` can
    /// show a `RespondingIndicatorView` colored/labeled for that specific
    /// bot instead of just a plain status string.
    var currentSpeakerName: String?
    var currentSpeakerColorHex: String?

    private let botDirectory: BotDirectory

    init(id: String = UUID().uuidString, name: String, memberBotIDs: [String], botDirectory: BotDirectory) {
        self.id = id
        self.name = name
        self.memberBotIDs = Array(memberBotIDs.prefix(Self.maxMembers))
        self.botDirectory = botDirectory
        self.displayMessages = GroupTranscriptStore.load(groupID: id)
    }

    var config: GroupChat {
        GroupChat(id: id, name: name, memberBotIDs: memberBotIDs)
    }

    /// Resolved fresh every access (not cached) — a member could be
    /// deleted from the sidebar entirely, and this should just quietly
    /// stop including it rather than holding a dangling reference.
    var members: [Bot] {
        let all = botDirectory.allBots()
        return memberBotIDs.compactMap { memberID in all.first { $0.id == memberID } }
    }

    func addMember(_ bot: Bot) {
        guard memberBotIDs.count < Self.maxMembers, !memberBotIDs.contains(bot.id) else { return }
        memberBotIDs.append(bot.id)
    }

    func removeMember(_ botID: String) {
        memberBotIDs.removeAll { $0 == botID }
    }

    func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        input = ""
        displayMessages.append(GroupMessage(speakerBotID: nil, speakerName: "You", text: text))
        persist()
        Task { await runTurn() }
    }

    private func persist() {
        GroupTranscriptStore.save(groupID: id, displayMessages)
    }

    /// `@Name` spans matched case-insensitively against actual member
    /// names, via the same greedy-longest-match tokenizer
    /// `MentionPillText` uses for pill rendering — so a multi-word name
    /// like "Dr. EggBot" is recognized here exactly the same way it's
    /// recognized visually, and the two can never disagree.
    private func mentionedMemberIDs(in text: String) -> Set<String> {
        let knownNames = Set(members.map { $0.name.lowercased() })
        let mentioned = MentionPillText.matchedNames(in: text, knownNames: knownNames)
        guard !mentioned.isEmpty else { return [] }
        // "@everyone" calls on every current member, same as naming each
        // one individually.
        if mentioned.contains("everyone") {
            return Set(members.map(\.id))
        }
        return Set(members.filter { mentioned.contains($0.name.lowercased()) }.map(\.id))
    }

    private func formatRecentTranscript(limit: Int = 30) -> String {
        displayMessages.suffix(limit).map { "\($0.speakerName): \($0.text)" }.joined(separator: "\n")
    }

    /// One turn: every member gets a chance to speak, sequentially — so
    /// bot #2 sees bot #1's reply already posted and doesn't redundantly
    /// repeat it — in mentioned-first order, then whatever's left in
    /// membership order. Not run concurrently, and deliberately not
    /// capped by a response count: the 6-member ceiling is the actual
    /// guardrail against noise, not an artificial "only N can talk" limit
    /// on top of it.
    private func runTurn() async {
        guard !isBusy else { return }
        isBusy = true
        status = "Thinking…"
        defer { isBusy = false; status = ""; currentSpeakerName = nil; currentSpeakerColorHex = nil }

        let lastText = displayMessages.last?.text ?? ""
        let mentioned = mentionedMemberIDs(in: lastText)
        let currentMembers = members
        let ordered = currentMembers.sorted { a, b in mentioned.contains(a.id) && !mentioned.contains(b.id) }

        for bot in ordered {
            let others = currentMembers.filter { $0.id != bot.id }.map(\.name)
            status = "\(bot.name) is thinking…"
            currentSpeakerName = bot.name
            currentSpeakerColorHex = bot.colorHex
            let reply = await bot.respondInGroup(
                groupName: name,
                otherMembers: others,
                transcriptSoFar: formatRecentTranscript(),
                wasMentioned: mentioned.contains(bot.id)
            )
            guard let reply else { continue }
            displayMessages.append(GroupMessage(speakerBotID: bot.id, speakerName: bot.name, text: reply))
            persist()
        }
    }

    /// A routine set up in `bot`'s own 1:1 chat, but targeting this group
    /// instead — see `Bot.fireRoutine`/`Routine.targetGroupID`. Unlike
    /// `runTurn`, `bot` always responds here (no `[[silent]]` opt-out):
    /// a routine is a directed, explicit instruction, not a passive
    /// "chime in if relevant" turn every member gets each time someone
    /// posts. Doesn't touch `isBusy`/`status` — those describe a live
    /// turn every member takes part in deciding on; this is just one
    /// bot, off-schedule, doing its own thing.
    func fireRoutine(for bot: Bot, instruction: String) async {
        let currentMembers = members
        guard currentMembers.contains(where: { $0.id == bot.id }) else { return }
        let others = currentMembers.filter { $0.id != bot.id }.map(\.name)
        guard let reply = await bot.fireRoutineInGroup(
            instruction: instruction, groupName: name, otherMembers: others, transcriptSoFar: formatRecentTranscript()
        ) else { return }
        displayMessages.append(GroupMessage(speakerBotID: bot.id, speakerName: bot.name, text: reply))
        persist()
    }
}
