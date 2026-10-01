import Foundation

/// Natural-language list of who is doing something: "Mr. Smith is working…",
/// "Mr. Smith and Bugbot are working…", "Mr. Smith, Bugbot, and Tai Lung are
/// working…". Pure so the grammar is tested, not eyeballed in the UI.
public enum StatusPhrase {
    /// "A", "A and B", "A, B, and C".
    public static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    /// `singular`/`plural` are the verb phrases, e.g. ("is working…", "are working…").
    public static func sentence(names: [String], singular: String, plural: String) -> String {
        guard !names.isEmpty else { return "" }
        return "\(joinNames(names)) \(names.count == 1 ? singular : plural)"
    }

    /// Index into a list of `count` colors that advances every `interval`
    /// seconds — used to swap a multi-bot line's color so it reads as "several".
    public static func colorIndex(at time: TimeInterval, interval: TimeInterval, count: Int) -> Int {
        guard count > 0, interval > 0 else { return 0 }
        return Int((time / interval).rounded(.down)) % count
    }
}
