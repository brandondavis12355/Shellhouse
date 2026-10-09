import Foundation

/// Which bots and group chats are pinned to the top of the sidebar, in the order they were pinned.
/// Pinning is a shortcut: a pinned item also stays in its normal list. Ids are the sidebar's own item
/// ids ("bot:<id>", "group:<id>").
public struct SidebarPins: Equatable, Sendable {
    public private(set) var ids: [String]

    public init(ids: [String] = []) {
        var seen = Set<String>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    public static func botID(_ id: String) -> String { "bot:\(id)" }
    public static func groupID(_ id: String) -> String { "group:\(id)" }

    public func contains(_ itemID: String) -> Bool { ids.contains(itemID) }

    @discardableResult
    public mutating func toggle(_ itemID: String) -> Bool {
        if let index = ids.firstIndex(of: itemID) {
            ids.remove(at: index)
            return false
        }
        ids.append(itemID)
        return true
    }

    /// Move a pinned item so it sits just before `target` (drag reorder inside the pinned section).
    public mutating func move(_ itemID: String, before target: String) {
        guard itemID != target, let from = ids.firstIndex(of: itemID), ids.contains(target) else { return }
        ids.remove(at: from)
        let to = ids.firstIndex(of: target) ?? ids.endIndex
        ids.insert(itemID, at: to)
    }

    /// Drop pins whose bot or group no longer exists.
    public mutating func prune(keeping valid: Set<String>) {
        ids.removeAll { !valid.contains($0) }
    }

    // MARK: persistence

    public static let defaultsKey = "sidebarPins"

    public static func load(from defaults: UserDefaults = .standard, key: String = defaultsKey) -> SidebarPins {
        SidebarPins(ids: defaults.stringArray(forKey: key) ?? [])
    }

    public func save(to defaults: UserDefaults = .standard, key: String = defaultsKey) {
        defaults.set(ids, forKey: key)
    }
}
