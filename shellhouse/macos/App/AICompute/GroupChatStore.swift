import Foundation

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
        try? FileManager.default.removeItem(at: fileURL(for: groupID))
    }
}
