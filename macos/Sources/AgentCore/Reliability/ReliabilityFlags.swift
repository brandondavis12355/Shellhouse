import Foundation

/// Switches for the accuracy features, one per group, ALL ON by default. Stored in user defaults
/// (`reliability.<name>`), read live so flipping one applies to the next step of a running chat.
/// Bug fixes (repeat detection, approval time off the clock, safety rules) are not switchable.
public enum Reliability {
    public enum Feature: String, CaseIterable, Sendable {
        case outputLimits, failureHints, loopGuards, callChecks, taskFocus, replyChecks, evidenceSharing, structuredGates, quickReports

        public var title: String {
            switch self {
            case .outputLimits: return "Keep tool output short"
            case .failureHints: return "Explain failures to the bot"
            case .loopGuards: return "Stop loops"
            case .callChecks: return "Check tool calls before running"
            case .taskFocus: return "Keep bots on task"
            case .replyChecks: return "Check replies before posting"
            case .evidenceSharing: return "Share evidence between bots"
            case .structuredGates: return "Reliable yes/no decisions"
            case .quickReports: return "Quick stand-ups and small talk"
            }
        }

        public var detail: String {
            switch self {
            case .outputLimits: return "Long command output keeps its start and end, and older bulky results shrink to a one-line stub."
            case .failureHints: return "After a failed command the bot gets a specific hint, and a warning when a chained command exits 0 around a failure."
            case .loopGuards: return "Nudges, then stops, a bot that repeats itself, ping-pongs between two actions, keeps getting the same result, or talks without acting."
            case .callChecks: return "Bad arguments, unknown tools and broken shell syntax get a precise correction instead of an approval prompt; text-written tool calls are recovered."
            case .taskFocus: return "Re-states the task every few steps and warns before the step budget runs out so the bot reports honestly instead of stalling."
            case .replyChecks: return "Replies that only announce intent, repeat an earlier message, or state versions/paths no tool returned are retried or trimmed; goal steps need real evidence."
            case .evidenceSharing: return "Each bot's report carries a short digest of what its own commands returned, so teammates can judge it."
            case .structuredGates: return "Yes/no decisions (should I reply, is this a task) use schema-constrained output so a small model cannot answer in free text."
            case .quickReports: return "Greetings and stand-ups are answered in one fast model call from what the bot already knows, with no commands."
            }
        }
    }

    public static func key(_ feature: Feature) -> String { "reliability.\(feature.rawValue)" }

    /// On unless explicitly switched off.
    public static func isOn(_ feature: Feature, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(feature)) == nil ? true : defaults.bool(forKey: key(feature))
    }

    public static func set(_ feature: Feature, _ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key(feature))
    }

    public static func resetAll(defaults: UserDefaults = .standard) {
        for feature in Feature.allCases { defaults.removeObject(forKey: key(feature)) }
    }
}
