import Foundation
import AgentCore

/// A named multi-bot group chat's identity/membership — the shared
/// transcript is separate (`GroupTranscriptStore`), same split as `Bot`/
/// `TranscriptStore` for the same reason: membership changes rarely,
/// messages append constantly.
struct GroupChat: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    /// Capped at 6 everywhere this is mutated (`GroupChatSession.addMember`,
    /// the create-group sheet) — not re-validated here, since this type is
    /// pure data and has no way to reject an invalid load.
    var memberBotIDs: [String]
    /// Goal owner default (see `GroupChatSession.pickOwner`). Optional so
    /// groups saved before goals existed still decode.
    var coordinatorBotID: String?
    var stallLimit: Int?
    var confirmTimeoutMinutes: Int?
    /// Set while this group is shared with friends through the relay.
    var relayGroupID: String?
}

enum GroupChatStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICompute", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("groups.json")
    }

    static func load() -> [GroupChat] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([GroupChat].self, from: data)) ?? []
    }

    static func save(_ groups: [GroupChat]) {
        guard let data = try? JSONEncoder().encode(groups) else {
            print("[GroupChatStore] failed to encode groups")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[GroupChatStore] failed to write groups.json: \(error)")
        }
    }
}

/// One line of a group chat — from the user (`speakerBotID == nil`) or a
/// specific member bot. `GroupChatSession` doesn't stream these in place
/// the way `Bot`'s own 1:1 chat does (see `DisplayMessage`'s doc comment);
/// a member's reply just appears once its isolated turn finishes.
struct GroupMessage: Codable, Identifiable {
    var id: String = UUID().uuidString
    var speakerBotID: String?
    var speakerName: String
    var text: String
    var timestamp: Date = Date()
    /// App-generated notice (goal set, step done, paused…), not a member
    /// or the user. Optional so older transcripts still decode.
    var isSystem: Bool?
    /// Set for a message written by a friend (not the owner, not a bot).
    /// Untrusted input: see `GroupChatSession.turnIsUntrusted`.
    var externalUserID: String?
    /// The relay's sequence number for a message that arrived from a friend.
    var relaySeq: Int?
}

enum GroupTranscriptStore {
    private static func fileURL(for groupID: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICompute/group-transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(groupID).json")
    }

    static func load(groupID: String) -> [GroupMessage] {
        guard let data = try? Data(contentsOf: fileURL(for: groupID)) else { return [] }
        return (try? JSONDecoder().decode([GroupMessage].self, from: data)) ?? []
    }

    private static let writeQueue = DispatchQueue(label: "GroupTranscriptStore.write", qos: .utility)

    /// Blocks until written (after anything already queued) — for app quit.
    static func saveNow(groupID: String, _ messages: [GroupMessage]) {
        writeQueue.sync { save(groupID: groupID, messages) }
    }

    static func saveInBackground(groupID: String, _ messages: [GroupMessage]) {
        writeQueue.async { save(groupID: groupID, messages) }
    }

    static func save(groupID: String, _ messages: [GroupMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else {
            print("[GroupTranscriptStore] failed to encode transcript for group \(groupID)")
            return
        }
        do {
            try data.write(to: fileURL(for: groupID), options: .atomic)
        } catch {
            print("[GroupTranscriptStore] failed to write transcript for group \(groupID): \(error)")
        }
    }

    static func delete(groupID: String) {
        writeQueue.async { try? FileManager.default.removeItem(at: fileURL(for: groupID)) }
    }
}

/// One group's goal — its own file, like transcripts, so goal churn never
/// rewrites `groups.json`.
enum GroupGoalStore {
    private static let writeQueue = DispatchQueue(label: "GroupGoalStore.write", qos: .utility)

    private static func fileURL(for groupID: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICompute/group-goals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(groupID).json")
    }

    static func load(groupID: String) -> GroupGoal? {
        guard let data = try? Data(contentsOf: fileURL(for: groupID)) else { return nil }
        return try? JSONDecoder().decode(GroupGoal.self, from: data)
    }

    static func saveNow(groupID: String, _ goal: GroupGoal?) {
        writeQueue.sync {
            guard let goal else { try? FileManager.default.removeItem(at: fileURL(for: groupID)); return }
            if let data = try? JSONEncoder().encode(goal) { try? data.write(to: fileURL(for: groupID), options: .atomic) }
        }
    }

    static func saveInBackground(groupID: String, _ goal: GroupGoal?) {
        writeQueue.async {
            guard let goal else { try? FileManager.default.removeItem(at: fileURL(for: groupID)); return }
            guard let data = try? JSONEncoder().encode(goal) else { return }
            try? data.write(to: fileURL(for: groupID), options: .atomic)
        }
    }
}
