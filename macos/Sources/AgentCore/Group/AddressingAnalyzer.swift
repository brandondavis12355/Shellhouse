import Foundation

// Who is a message for? Deterministic (no model call), so the answer is the same
// every time and can be tested: explicit @mentions, plain-name mentions, "the whole
// room" addresses (everyone / guys / team / a bare greeting), "anyone ...?" questions,
// and acknowledgements that need no reply.

public struct GroupMember: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Short role/tagline ("Main Engineer"); used to pick the best-fit responder.
    public let role: String
    public init(id: String, name: String, role: String = "") {
        self.id = id
        self.name = name
        self.role = role
    }
}

public struct Addressing: Sendable, Equatable {
    /// Members named with an `@` (the caller supplies these; `@everyone` expands to all).
    public var explicitIDs: Set<String> = []
    /// Members named without an `@` ("Bugbot, can you...", "thanks Tai Lung").
    public var nameIDs: Set<String> = []
    /// Addressed to the room as a whole: "everyone", "guys", "team", "hey all", or a bare greeting.
    public var isCollective = false
    /// "Anyone know...?", "who can...?": at least one member should answer.
    public var isAnyoneQuestion = false
    public var isGreeting = false
    /// "ok", "thanks", "👍": no reply is needed.
    public var isAcknowledgement = false
    /// Small talk or a short question that needs no tools or sandbox work: answered with one
    /// direct model call instead of a full agent run (seconds, not minutes).
    public var isConversational = false
    /// A stand-up / status check-in: each member reports from what it already knows, no commands needed.
    public var isStatusRequest = false

    public var addressedIDs: Set<String> { explicitIDs.union(nameIDs) }
    public init() {}
}

public enum AddressingAnalyzer {
    // MARK: vocabulary

    static let nameStopWords: Set<String> = [
        "the", "and", "bot", "bots", "team", "all", "you", "your", "hey", "hello", "chat", "group", "that", "this",
        "with", "from", "have", "what", "when", "will", "just", "good", "mr", "mrs", "ms", "dr",
    ]

    /// Words that address the whole room on their own.
    static let collectiveWords: [String] = [
        "everyone", "everybody", "everyones", "y'all", "yall", "ya'll", "guys", "gals", "folks", "peeps",
        "you all", "you guys", "all of you", "you both", "you two", "you three", "both of you", "everyone's",
    ]

    /// "hey all", "morning team": a greeting or thanks directed at a group noun. Nouns that are also
    /// everyday words ("team", "crew", "all") only count right after a greeting or at the start of a
    /// message ("team, please..."), so "update the team doc" does not call on everybody.
    static let collectivePhrase = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])(?:(?:hi|hello|hey|hiya|yo|morning|afternoon|evening|howdy|sup|hola|thanks|thank you|cheers|bye|goodbye|night|gn|gm|ok|okay|alright|right|so|attention|dear)\s+(?:all|team|crew|squad|gang|people|friends|y'all|yall)|^(?:team|crew|squad|gang|all)\s*[,:!.-])(?![\p{L}\p{N}_])"#,
        options: [.caseInsensitive]
    )

    static let greetingWords: Set<String> = [
        "hi", "hello", "hey", "heya", "hiya", "yo", "howdy", "sup", "hola", "morning", "afternoon", "evening", "good",
        "gm", "gn", "night", "greetings", "hallo", "ahoy", "there", "what's", "whats", "up", "how", "are", "is", "it",
        "going", "doing", "how's", "hows", "you", "ya", "u", "today", "everyone", "everybody", "guys", "all", "team", "folks", "y'all",
    ]

    static let anyonePatterns: [String] = [
        #"\banyone\b"#, #"\banybody\b"#, #"\bsomeone\b"#, #"\bsomebody\b"#, #"\bwho can\b"#, #"\bwho could\b"#,
        #"\bwho wants\b"#, #"\bwho's able\b"#, #"\bwho is able\b"#, #"\bany of you\b"#, #"\bwhich of you\b"#,
        #"\bwho (?:knows|has|is)\b"#, #"\bsomeone (?:can|could)\b"#,
    ]

    static let ackWords: Set<String> = [
        "ok", "okay", "k", "kk", "thanks", "thank", "you", "thx", "ty", "tyvm", "cool", "nice", "great", "got", "it",
        "perfect", "awesome", "np", "no", "problem", "sounds", "good", "lol", "haha", "yep", "yes", "yeah", "sure",
        "fine", "alright", "right", "cheers", "appreciated", "appreciate", "that", "works", "thank", "so", "much",
        "very", "bye", "goodbye", "later", "cya", "see", "ya", "night", "gn", "noted", "understood", "ack",
        "all", "good", "well", "done", "wow", "love", "excellent", "brilliant", "super", "gotcha", "👍", "🙏",
    ]

    // MARK: analysis

    public static func analyze(text: String, members: [GroupMember], explicitMentionIDs: Set<String> = []) -> Addressing {
        var result = Addressing()
        result.explicitIDs = explicitMentionIDs.intersection(members.map(\.id))

        var working = normalize(text)

        // Plain-name mentions (members already @mentioned don't need it).
        let phrases = namePhrases(for: members)
        for member in members where !result.explicitIDs.contains(member.id) {
            for phrase in phrases[member.id] ?? [] where containsWord(phrase, in: working) {
                result.nameIDs.insert(member.id)
                break
            }
        }
        // Remove every member name (and @ forms) so what's left is the "intent" of the message.
        for member in members {
            for phrase in (phrases[member.id] ?? []).sorted(by: { $0.count > $1.count }) {
                working = removeWord(phrase, from: working)
            }
        }
        working = working.replacingOccurrences(of: "@", with: " ")

        // Whole-room addresses.
        let hasCollectiveWord = collectiveWords.contains { containsWord($0, in: working) }
            || collectivePhrase.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)) != nil
        let tokens = words(in: working)
        let greetingOnly = !tokens.isEmpty && tokens.allSatisfy { greetingWords.contains($0) }
        result.isGreeting = greetingOnly || (tokens.first.map { ["hi", "hello", "hey", "heya", "hiya", "yo", "howdy", "hola", "greetings", "morning"].contains($0) } ?? false)

        result.isAnyoneQuestion = anyonePatterns.contains { working.range(of: $0, options: .regularExpression) != nil }

        let anyoneAsCollective = false   // "anyone" asks for one answer, not a roll call
        result.isCollective = hasCollectiveWord
            || (greetingOnly && result.addressedIDs.isEmpty)
            || anyoneAsCollective
        // "hey guys, can anyone ..." is still a question for any one of them, not a roll call.
        if result.isAnyoneQuestion && !greetingOnly { result.isCollective = hasCollectiveWord && !result.isAnyoneQuestion }

        // Acknowledgements ("thanks guys!", "ok 👍") need no reply.
        let remaining = tokens.filter { !collectiveWords.contains($0) && !["all", "team", "crew", "squad", "gang", "people", "friends"].contains($0) }
        let emojiOnly = !text.isEmpty && words(in: normalize(text)).isEmpty
        result.isAcknowledgement = emojiOnly || (!remaining.isEmpty && remaining.allSatisfy { ackWords.contains($0) } && !working.contains("?"))
        result.isStatusRequest = isStatusRequest(text)
        result.isConversational = !result.isAcknowledgement && !result.isStatusRequest && isSmallTalk(raw: text, tokens: tokens, greetingOnly: greetingOnly)
        return result
    }

    /// Verbs/nouns that mean "go do something on a machine". Only a safety net: the main rule is that
    /// anything that is not a greeting or a short question goes to the full agent.
    static let workWords: Set<String> = [
        "run", "build", "install", "create", "make", "fix", "write", "edit", "delete", "remove", "deploy", "download",
        "upload", "search", "browse", "scrape", "fetch", "clone", "commit", "push", "pull", "test", "debug", "implement",
        "refactor", "generate", "execute", "script", "code", "file", "files", "folder", "repo", "repository", "server",
        "docker", "terminal", "shell", "command", "database", "configure", "set", "setup", "update", "check",
        "doublecheck", "verify", "confirm", "ensure", "investigate", "analyze", "analyse", "review", "summarize",
        "summarise", "research", "find", "open", "read", "list", "schedule", "remind", "routine", "task", "goal", "plan",
        "report", "compile", "scan", "monitor", "vm", "vms", "machine", "machines", "binary", "cli", "version",
        "package", "packages", "sudo", "apt", "please", "tell", "show", "look", "status", "double", "validate",
    ]

    /// Small talk = a greeting, or a SHORT QUESTION with no work in it. Statements and commands (even
    /// short ones) are work: a model answering "check X" from imagination is worse than a slow real check.
    static func isSmallTalk(raw: String, tokens: [String], greetingOnly: Bool) -> Bool {
        if greetingOnly { return true }
        guard !tokens.isEmpty, tokens.count <= 14, raw.contains("?") else { return false }
        let lowered = raw.lowercased()
        if lowered.contains("```") || lowered.contains("http") || lowered.contains("/") || lowered.contains("\\") { return false }
        return !tokens.contains { workWords.contains($0) }
    }

    private static let statusPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:stand[\s-]?ups?|daily scrum|status\s+(?:updates?|reports?|check)|your\s+status|check[\s-]?ins?|blockers?|progress\s+(?:update|report)|what\s+(?:are|have)\s+you\s+(?:you\s+)?(?:working\s+on|been\s+(?:working|doing)|done)|what(?:'s| is)\s+on\s+your\s+plate|what\s+did\s+you\s+(?:do|work\s+on)|report\s+in|how(?:'s| is| are)\s+(?:we|(?:the|our)\s+(?:goal|project|work|plan|progress|team)|progress)\s+(?:doing|going|looking|coming(?:\s+along)?|progressing)|how\s+far\s+along|where\s+are\s+we\s+(?:at|on|with)|what(?:'s| is)\s+the\s+(?:status|progress|latest)|any\s+(?:progress|updates?)\s+on|(?:goal|project)\s+status)(?![\p{L}\p{N}])"#,
        options: [.caseInsensitive]
    )

    /// "Daily Stand-up: please provide your status updates and any blockers" and the like.
    public static func isStatusRequest(_ text: String) -> Bool {
        let t = normalize(text)
        guard !t.isEmpty, t.count <= 600 else { return false }
        return statusPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    // MARK: helpers

    static func normalize(_ text: String) -> String {
        var t = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        for c in ["*", "_", "`", "~", ">", "#"] { t = t.replacingOccurrences(of: c, with: " ") }
        t = t.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func words(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" { current.append(ch) }
            else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }

    static func containsWord(_ phrase: String, in text: String) -> Bool {
        wordRegex(phrase).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func removeWord(_ phrase: String, from text: String) -> String {
        wordRegex(phrase).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    private static func wordRegex(_ phrase: String) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])@?"# + escaped + #"(?![\p{L}\p{N}_])"#, options: [.caseInsensitive])
    }

    /// Every way a member can be named plainly: its full name, plus any single word of it that is
    /// distinctive (4+ letters, not a common word, and not shared with another member).
    static func namePhrases(for members: [GroupMember]) -> [String: [String]] {
        var tokenOwners: [String: Set<String>] = [:]
        for m in members {
            for token in words(in: normalize(m.name)) { tokenOwners[token, default: []].insert(m.id) }
        }
        var out: [String: [String]] = [:]
        for m in members {
            let full = normalize(m.name)
            var phrases: [String] = full.isEmpty ? [] : [full]
            for token in words(in: full) where token.count >= 4 && !nameStopWords.contains(token) && tokenOwners[token]?.count == 1 && token != full {
                phrases.append(token)
            }
            out[m.id] = phrases
        }
        return out
    }
}
