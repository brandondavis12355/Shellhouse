import Foundation

/// One reusable command from a checked bot-to-bot reply. A one-off fact has no command, so it saves nothing.
public enum ProcessNote {
    public static func command(in reply: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "`([^`\\n]{3,120})`") else { return nil }
        let range = NSRange(reply.startIndex..., in: reply)
        guard let match = regex.firstMatch(in: reply, options: [], range: range),
              let span = Range(match.range(at: 1), in: reply) else { return nil }
        let command = String(reply[span]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.contains(" ") || command.hasPrefix("/") || command.hasPrefix("./") else { return nil }
        return command
    }
}
