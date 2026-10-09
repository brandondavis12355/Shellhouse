import Foundation

/// The ordered message log a friend's app keeps for a group they joined:
/// dedupes by relay sequence number (the stream can redeliver after a
/// reconnect), stays sorted by seq, and is bounded so a very long-lived group
/// can't grow without limit.
public struct JoinedGroupLog: Sendable, Equatable {
    public static let defaultLimit = 2000

    public private(set) var messages: [RelayMessage] = []
    private let limit: Int

    public init(limit: Int = JoinedGroupLog.defaultLimit) { self.limit = max(1, limit) }

    /// Returns how many messages were actually new.
    @discardableResult
    public mutating func append(contentsOf incoming: [RelayMessage]) -> Int {
        var known = Set(messages.map(\.seq))
        var added = 0
        for message in incoming where !known.contains(message.seq) {
            known.insert(message.seq)
            messages.append(message)
            added += 1
        }
        if added > 0 {
            messages.sort { $0.seq < $1.seq }
            if messages.count > limit { messages.removeFirst(messages.count - limit) }
        }
        return added
    }

    public var latestSeq: Int { messages.last?.seq ?? 0 }

    /// Messages from other people/bots after `seq` — what a sidebar badge counts.
    public func unreadCount(after seq: Int, myUserID: String) -> Int {
        messages.filter { $0.seq > seq && !($0.kind == .human && $0.speakerUserId == myUserID) && $0.kind != .system }.count
    }
}

public enum JoinedGroupFilter {
    /// Groups I'm a member of but don't own. Owned groups are already local
    /// chats (shared outward), so they're not listed again as "joined".
    public static func joined(_ groups: [RelayGroupSummary], myUserID: String) -> [RelayGroupSummary] {
        groups.filter { $0.ownerId != myUserID }
    }
}
