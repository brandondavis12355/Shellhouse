import Foundation

// Accuracy scaffolding for the agent loop, drawn from published agent research (SWE-agent's
// agent-computer-interface ablations, OpenHands' stuck detector, grounded-verification findings,
// Reflexion-style environment feedback). Everything here is pure and deterministic: it makes the model's
// view of the world more accurate and catches known failure patterns without asking a model to judge itself.

// MARK: - 1. Bounded observations, 2. failure hints, 3. masked-failure warnings

public enum ObservationPolicy {
    /// Looking, not changing: `cd somewhere && git log && ls` reads like `ls`, so repeating it is a loop.
    public static func isObservation(_ decision: GuardrailDecision) -> Bool {
        decision.effect == .observe
            || (!decision.rules.isEmpty && decision.rules.allSatisfy { $0.hasPrefix("read.") || $0 == "exec.cd" || $0 == "shell.read_only" })
    }

    /// A single tool field longer than this is shown as head + tail with an explicit omission marker.
    /// (SWE-agent: bounded, summarized observations beat raw dumps.)
    public static let maxFieldCharacters = 6_000

    /// Keeps the start and the end of long text (errors and results usually live there) and says what was cut.
    public static func truncateMiddle(_ text: String, limit: Int = maxFieldCharacters) -> String {
        guard text.count > limit, limit >= 200 else { return text }
        let keep = limit / 2
        let head = text.prefix(keep)
        let tail = text.suffix(keep)
        let omitted = text.count - 2 * keep
        let lines = text.dropFirst(keep).dropLast(keep).filter { $0 == "\n" }.count
        return "\(head)\n… [\(omitted) characters (\(lines) lines) omitted — narrow the command (grep, head, tail, a path) to see them] …\n\(tail)"
    }

    /// Bounded copy of an observation: every long string field is truncated in the middle.
    public static func bounded(_ observation: [String: Any], limit: Int = maxFieldCharacters) -> [String: Any] {
        var out = observation
        for (key, value) in observation {
            if let text = value as? String, text.count > limit { out[key] = truncateMiddle(text, limit: limit) }
        }
        return out
    }

    private static let failureMarkers = [
        "command not found", "No such file or directory", "Permission denied", "cannot access", "cannot open",
        "is not recognized", "not found", "Traceback (most recent call last)", "fatal:", "Segmentation fault",
        "Operation not permitted", "Could not resolve host", "Connection refused", "E: Unable to locate package",
    ]

    /// Grounded feedback for the model: what the result actually says (Reflexion's "environment feedback"),
    /// including the common trap where chaining (`cmd; echo "exit=$?"`) makes the tool exit 0 while the
    /// output shows a failure. Adds `warning` / `hint` keys; never changes the original fields.
    public static func annotate(tool: String, observation: [String: Any]) -> [String: Any] {
        guard tool == "run_shell" else { return observation }
        var out = observation
        let exit = (observation["exit_code"] as? Int) ?? (observation["exit_code"] as? NSNumber)?.intValue ?? 0
        let stdout = observation["stdout"] as? String ?? ""
        let stderr = observation["stderr"] as? String ?? ""
        let combined = stdout + "\n" + stderr
        let shown = failureMarkers.first { combined.contains($0) }

        if exit == 0, let marker = shown {
            out["warning"] = "exit_code is 0, but the output contains \"\(marker)\". The command may have failed inside a chain (`;`, `&&`, `|`, `echo exit=$?`): treat the output, not exit_code, as the result."
        }
        if exit != 0 || shown != nil {
            if let hint = recoveryHint(for: combined) { out["hint"] = hint }
        }
        if exit == 0, shown == nil, observation["job_id"] == nil, combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["note"] = "No output, exit code 0. A command that only changes things (writes a file, copies, sleeps, installs quietly) "
                + "normally prints nothing, so this usually means it worked; don't run it again. For a search or lookup it means nothing was found."
        }
        return out
    }

    static func recoveryHint(for text: String) -> String? {
        if AuthFailure.matches(text) { return AuthFailure.hint }
        let t = text.lowercased()
        if t.contains("command not found") { return "That program is not installed on this VM. Check with `command -v <name>`; install with `sudo apt-get update && sudo apt-get install -y <package>` if appropriate, or use another tool." }
        if t.contains("unable to locate package") { return "Package lists may be empty: run `sudo apt-get update` first, then retry." }
        if t.contains("permission denied") || t.contains("operation not permitted") { return "Not allowed as this user. Check ownership with `ls -l`, use a path under /workspace or /home, or `sudo` if installing system packages." }
        if t.contains("no such file or directory") || t.contains("cannot access") { return "That path does not exist. List the parent directory (`ls -la <parent>`) before retrying with a corrected path." }
        if t.contains("could not resolve host") || t.contains("connection refused") || t.contains("timed out") { return "Network target unreachable from this VM. Do not retry blindly: check the address, or report that it is unreachable." }
        if t.contains("traceback (most recent call last)") { return "Read the last line of the traceback; fix that one cause rather than rewriting everything." }
        return nil
    }

    // MARK: - 6. stale observations leave the context (SWE-agent keeps only the last few in full)

    /// Replaces older, large tool results with a one-line stub, keeping the newest `keepLast` intact.
    /// The assistant's own messages and the user's messages are never touched.
    ///
    /// Collapses in batches of `batch`: rewriting an early message makes the model server re-read the
    /// conversation from there, so doing it every few results instead of on every step keeps more of the
    /// prompt cached. Up to `batch - 1` extra results stay in full in between.
    public static func collapseStale(_ messages: [ChatMessage], keepLast: Int = 8, minCharacters: Int = 700, batch: Int = 4) -> [ChatMessage] {
        let toolIndices = messages.indices.filter { messages[$0].role == .tool }
        let excess = toolIndices.count - keepLast
        let step = max(1, batch)
        guard excess >= step else { return messages }
        let stale = Set(toolIndices.prefix(excess - excess % step))
        var out = messages
        for index in stale {
            let message = messages[index]
            guard message.content.count >= minCharacters, !message.content.hasPrefix("[earlier output") else { continue }
            let name = message.toolName ?? "tool"
            let firstLine = message.content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let gist = String(firstLine.prefix(120))
            out[index] = ChatMessage(
                role: .tool,
                content: "[earlier output of \(name) omitted to keep the conversation focused (\(message.content.count) characters): \(gist)…]",
                toolName: message.toolName
            )
        }
        return out
    }
}

// MARK: - 4/5. stuck patterns (OpenHands detector: alternating, monologue)

/// How a tool result went, for the "stop and tell your user" rule (see `AgentRuntime`).
public enum FailureCheck {
    public enum Kind: Equatable { case ok, failed, blocked, hard }

    /// `hard`: blocked, denied or missing credentials: nothing to retry. `failed`: an error, a non-zero
    /// exit, or exit 0 with failure text in the output (the warning `ObservationPolicy.annotate` adds).
    public static func kind(_ shown: [String: Any]) -> Kind {
        let text = ((shown["error"] as? String) ?? "") + "\n" + ((shown["stdout"] as? String) ?? "") + "\n" + ((shown["stderr"] as? String) ?? "")
        // A block comes with an allowed alternative to act on; the user saying no is a real stop.
        if let error = shown["error"] as? String, error.hasPrefix("blocked") { return .blocked }
        if let error = shown["error"] as? String, error.hasPrefix("denied by user") { return .hard }
        let exit = (shown["exit_code"] as? Int) ?? (shown["exit_code"] as? NSNumber)?.intValue ?? 0
        let failed = shown["error"] != nil || exit != 0 || shown["warning"] != nil
        if failed, AuthFailure.matches(text) { return .hard }
        return failed ? .failed : .ok
    }

    public static let stopNotice = "[problem] That didn't work. Unless you know the specific fix (a typo you can see, a "
        + "package to install, a path to correct), stop here: finish_task with outcome \"blocked\", telling your user what "
        + "failed, what you tried, and what you need from them. Don't probe with more commands or try workarounds first. "
        + "(Missing credentials: request_credentials.)"

    public static let blockedNotice = "[blocked] That action isn't allowed, but the task can usually still be done. Take the "
        + "allowed route the message gives (or another one you're sure is allowed), or move on to the parts you can do. Don't retry "
        + "the blocked action. Mention what you couldn't do in your reply."

    /// The same failure this many times in a row stops the run with a report.
    public static let stopAfter = 3
    /// Failures of any kind in a row before the run stops.
    public static let stopAfterAny = 6

    /// What identifies "the same failure": the error or stderr text, numbers ignored.
    public static func key(_ shown: [String: Any]) -> String {
        let text = (shown["error"] as? String) ?? ((shown["stderr"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (shown["stdout"] as? String) ?? "")
        return String(text.suffix(300)).replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
    }
}

public struct StuckDetector: Sendable {
    public enum Verdict: Equatable, Sendable {
        case fine
        case nudge(String)
        case abort(String)
    }

    private var recent: [String] = []
    private var plainRepliesInARow = 0
    private var nudgedAlternation = false

    public init() {}

    /// An action just ran. `fingerprint` should be a normalized signature of the call (see `AgentRuntime.repeatFingerprint`).
    public mutating func recordAction(_ fingerprint: String) -> Verdict {
        plainRepliesInARow = 0
        recent.append(fingerprint)
        if recent.count > 12 { recent.removeFirst(recent.count - 12) }
        // A,B,A,B,A,B: two different actions ping-ponging. Nudge at 6 in a row, stop at 8.
        func alternates(_ count: Int) -> Bool {
            guard recent.count >= count else { return false }
            let tail = Array(recent.suffix(count))
            guard tail[0] != tail[1] else { return false }
            return tail.enumerated().allSatisfy { $0.element == tail[$0.offset % 2] }
        }
        if alternates(8) { return .abort("alternated between the same two actions without making progress") }
        if alternates(6), !nudgedAlternation {
            nudgedAlternation = true
            return .nudge("You are alternating between the same two actions and getting the same results. Stop and take a different approach, or report what is blocking you.")
        }
        return .fine
    }

    /// The model answered in plain text without calling a tool (monologue).
    public mutating func recordPlainReply() -> Verdict {
        plainRepliesInARow += 1
        switch plainRepliesInARow {
        case 3: return .nudge("You have replied three times without calling a tool. Either call the next tool you need, or call finish_task with your final answer.")
        case 5...: return .abort("kept replying in plain text without using a tool or finishing")
        default: return .fine
        }
    }

    /// Something changed in the world: earlier patterns no longer apply.
    public mutating func reset() {
        recent.removeAll()
        nudgedAlternation = false
    }
}

// MARK: - 7. tool-call validation, 8. shell lint

public enum ToolCallValidator {
    /// A precise, actionable complaint about a call, or nil if it is well-formed.
    public static func problem(with call: ToolCall, schemas: [ToolSchema]) -> String? {
        guard let schema = schemas.first(where: { $0.name == call.name }) else {
            let names = schemas.map(\.name)
            if let close = closestName(to: call.name, in: names) {
                return "unknown tool '\(call.name)': there is no tool by that name. Did you mean '\(close)'? Available tools: \(names.sorted().joined(separator: ", "))."
            }
            return "unknown tool '\(call.name)': there is no tool by that name. Available tools: \(names.sorted().joined(separator: ", "))."
        }
        let required = (schema.parameters["required"] as? [String]) ?? []
        let properties = (schema.parameters["properties"] as? [String: Any]) ?? [:]
        var missing: [String] = []
        var wrongType: [String] = []
        for key in required {
            guard let value = call.arguments[key]?.value else { missing.append(key); continue }
            if let text = value as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(call.name == "finish_task" && key != "summary") {
                missing.append(key)
            }
        }
        for (key, argument) in call.arguments {
            guard let spec = properties[key] as? [String: Any], let type = spec["type"] as? String else { continue }
            if !matches(argument.value, type: type) { wrongType.append("'\(key)' should be \(type)") }
        }
        guard !missing.isEmpty || !wrongType.isEmpty else { return nil }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("missing required " + missing.map { "'\($0)'" }.joined(separator: ", ")) }
        if !wrongType.isEmpty { parts.append(wrongType.joined(separator: "; ")) }
        return "Bad arguments for \(call.name): \(parts.joined(separator: "; ")). Call it again with the corrected arguments."
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "integer": return value is Int || (value as? Double).map { $0 == $0.rounded() } == true
        case "number": return value is Int || value is Double || value is NSNumber
        case "boolean": return value is Bool
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return true
        }
    }

    static func closestName(to name: String, in names: [String]) -> String? {
        let target = name.lowercased().replacingOccurrences(of: "-", with: "_")
        var best: (name: String, distance: Int)?
        for candidate in names {
            let d = editDistance(target, candidate.lowercased())
            if d <= max(2, candidate.count / 3), best == nil || d < best!.distance { best = (candidate, d) }
        }
        // Common model habits.
        let aliases = ["run_command": "run_shell", "shell": "run_shell", "bash": "run_shell", "execute": "run_shell", "exec": "run_shell",
                       "read": "read_file", "cat": "read_file", "ls": "list_files", "finish": "finish_task", "done": "finish_task", "final_answer": "finish_task"]
        if let alias = aliases[target], names.contains(alias) { return alias }
        return best?.name
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

public enum ShellLint {
    /// A problem that makes the command certainly wrong (so it is refused before an approval is requested).
    public static func problem(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "The command is empty." }
        let analysis = ShellAnalyzer.analyze(command)
        for issue in analysis.unresolved {
            if issue.contains("unterminated") {
                return "Your command has a syntax problem (\(issue)). Check quotes and brackets (a stray quote inside echo \"…\" is the usual cause) and send it again."
            }
        }
        // Prose pasted instead of a command.
        if trimmed.hasPrefix("```") || trimmed.hasSuffix("```") {
            return "The command contains markdown code fences (```). Send only the shell command itself."
        }
        return nil
    }
}

// MARK: - 10/11. reply quality, 4. grounded evidence

public enum ReplyQuality {
    private static let narrationOpeners = [
        "i'll ", "i will ", "let me ", "i am going to ", "i'm going to ", "first, i", "now i", "now, i", "going to ", "i should ",
        "my plan", "to do this", "okay, ", "ok, let", "sure, i'll", "sure! i'll",
    ]

    /// True when a "reply" only announces what the bot is about to do instead of doing it.
    /// The reply's LAST sentence says what the bot is about to do ("…returned Not Found. Let me try
    /// the correct URL."). Such a reply opens with a fact, so `looksLikeNarration` misses it, but the
    /// work isn't finished: it must not end the turn.
    public static func endsWithIntent(_ text: String) -> Bool {
        let sentences = text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 3 }
        guard let last = sentences.last, !last.hasPrefix("let me know") else { return false }
        let intents = ["let me ", "i'll ", "i will ", "i’ll ", "i am going to ", "i'm going to ", "i’m going to ",
                       "next, i", "now i", "i need to ", "i should ", "i'm now ", "i am now "]
        return intents.contains { last.hasPrefix($0) || last.contains(" " + $0) || last.contains(", " + $0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func looksLikeNarration(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        if t.count > 400 { return false }   // a long message has content
        if narrationOpeners.contains(where: { t.hasPrefix($0) }) { return true }
        return t.hasSuffix(":") && t.count < 160
    }

    /// Word-set overlap, 0...1, ignoring case, punctuation and very short words.
    public static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Is `candidate` (nearly) a repeat of something already said?
    public static func isDuplicate(_ candidate: String, of earlier: [String], threshold: Double = 0.85) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return false }
        return earlier.contains { similarity(trimmed, $0) >= threshold }
    }
}

/// Whether a finished task's summary should be tucked away as "Done — tap for summary" (it only
/// repeats a reply already shown this turn) or shown as the reply itself (nothing was shown yet, or
/// what was shown was a step like "Let me check…", not the answer).
public enum SummaryDisplay {
    public static func collapses(summary: String, shownThisTurn: [String]) -> Bool {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return true }
        return shownThisTurn.contains { shown in
            let r = shown.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !r.isEmpty else { return false }
            return r.contains(s) || s.contains(r) || ReplyQuality.similarity(s, r) >= 0.5
        }
    }
}

/// Tool results are stored as JSON, which escapes every `/` as `\/`, so a
/// path the tools really returned ("/usr/bin/gh") would never be found in
/// them verbatim. Lowercase and undo that escaping before searching.
enum ObservationText {
    static func searchable(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/").lowercased()
    }
}

public enum EvidenceGrounding {
    private static let filler: Set<String> = ["this", "that", "with", "from", "have", "were", "which", "what", "when", "then", "than", "ran", "output",
                                              "result", "showed", "shows", "returned", "command", "step", "done", "worked", "works", "exit", "code", "verified", "confirmed", "checked"]

    /// A completion claim is grounded when something distinctive in the evidence ("2.46.0", "/usr/bin/gh", a
    /// file name) really appears in what the tools returned during this run. Self-assessment alone is not
    /// evidence (research on self-graded loops found a "progress mirage"); the world's output is.
    public static func isGrounded(evidence: String, observations: String) -> Bool {
        let haystack = ObservationText.searchable(observations)
        guard !haystack.isEmpty else { return false }
        let tokens = evidence.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "/" || $0 == "-" || $0 == "_") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".-/_")) }
            .filter { $0.count >= 4 && !filler.contains($0) }
        // Distinctive: a number, a path, or a dotted name: things a model would not just say by habit.
        let distinctive = tokens.filter { t in t.contains(where: \.isNumber) || t.contains("/") || t.contains(".") }
        return distinctive.contains { haystack.contains($0) }
    }
}

// MARK: - 12. the model's sense of time

public enum TemporalContext {
    /// "Right now it is Tuesday, 6 October 2026, 9:18 AM (America/Los_Angeles)."
    public static func promptLine(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "EEEE, d MMMM yyyy, h:mm a"
        return "Right now it is \(f.string(from: now)) (\(timeZone.identifier)). Use this for any date or time reasoning; never guess the date."
    }
}

// MARK: - Round two: claims, small-model recovery, evidence sharing

/// CRITIC / Chain-of-Verification, deterministic version: specifics a reply states (versions, paths, addresses,
/// hashes) must appear somewhere the bot could have seen them: its tool output, the chat, or its own records.
public enum ClaimCheck {
    private static let specificPattern = try! NSRegularExpression(
        pattern: #"(?<![\w./-])(?:/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+|\d+(?:\.\d+){1,}[A-Za-z0-9_-]*|\b[0-9a-f]{7,40}\b)(?![\w])"#
    )

    /// Distinctive tokens in `reply` (paths with 2+ segments, dotted versions/addresses, long hex ids).
    public static func specifics(in reply: String) -> [String] {
        let range = NSRange(reply.startIndex..., in: reply)
        var out: [String] = []
        for match in specificPattern.matches(in: reply, range: range) {
            guard let r = Range(match.range, in: reply) else { continue }
            let token = String(reply[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)"))
            if token.count >= 4, !out.contains(token) { out.append(token) }
        }
        return out
    }

    /// Specifics in `reply` that appear in none of `sources`.
    public static func unsupported(in reply: String, sources: String) -> [String] {
        let haystack = ObservationText.searchable(sources)
        return specifics(in: reply).filter { !haystack.contains($0.lowercased()) }
    }

    /// The reply with every line that states an unsupported specific removed (last resort after a retry).
    public static func removingLines(stating tokens: [String], from reply: String) -> String {
        guard !tokens.isEmpty else { return reply }
        let kept = reply.components(separatedBy: "\n").filter { line in !tokens.contains { line.contains($0) } }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Small local models often print the tool call as text instead of using the tool-call channel:
/// `{"name":"run_shell","arguments":{...}}`, `Action: {...}`, or a fenced json block. Recover those.
public enum ToolCallRecovery {
    public static func extract(from content: String, toolNames: Set<String>) -> ToolCall? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count < 4_000, text.contains("{") else { return nil }
        for candidate in jsonObjects(in: text) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let name = (object["name"] as? String) ?? (object["tool"] as? String) ?? (object["function"] as? String)
            guard let name, toolNames.contains(name) else { continue }
            var arguments = (object["arguments"] as? [String: Any]) ?? (object["parameters"] as? [String: Any]) ?? (object["args"] as? [String: Any]) ?? [:]
            if arguments.isEmpty, let raw = object["arguments"] as? String, let d = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { arguments = parsed }
            return ToolCall(name: name, arguments: arguments.mapValues { AnyCodable($0) })
        }
        return nil
    }

    /// Top-level balanced `{...}` spans, in order.
    static func jsonObjects(in text: String) -> [String] {
        var out: [String] = []
        var depth = 0, start: String.Index?, inString = false, escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { if depth == 0 { start = i }; depth += 1 }
            else if c == "}", depth > 0 {
                depth -= 1
                if depth == 0, let s = start { out.append(String(text[s...i])); start = nil }
            }
            i = text.index(after: i)
        }
        return out
    }
}

extension ToolCallValidator {
    /// Fixes harmless type slips before validating: "30" → 30, "true" → true, 3.0 → 3, a lone string for an array.
    public static func coerced(_ call: ToolCall, schemas: [ToolSchema]) -> ToolCall {
        guard let schema = schemas.first(where: { $0.name == call.name }),
              let properties = schema.parameters["properties"] as? [String: Any] else { return call }
        var args = call.arguments
        for (key, argument) in call.arguments {
            guard let spec = properties[key] as? [String: Any], let type = spec["type"] as? String else { continue }
            switch (type, argument.value) {
            case ("integer", let s as String): if let n = Int(s.trimmingCharacters(in: .whitespaces)) { args[key] = AnyCodable(n) }
            case ("integer", let d as Double): if d == d.rounded() { args[key] = AnyCodable(Int(d)) }
            case ("number", let s as String): if let n = Double(s.trimmingCharacters(in: .whitespaces)) { args[key] = AnyCodable(n) }
            case ("boolean", let s as String):
                if ["true", "yes"].contains(s.lowercased()) { args[key] = AnyCodable(true) }
                else if ["false", "no"].contains(s.lowercased()) { args[key] = AnyCodable(false) }
            case ("array", let s as String): args[key] = AnyCodable([s])
            case ("string", let n as Int): args[key] = AnyCodable(String(n))
            default: break
            }
        }
        return ToolCall(name: call.name, arguments: args)
    }
}

public enum EvidenceDigest {
    /// A compact, readable excerpt of what a run's tools returned, shared with the other members so they can
    /// judge a report by what was actually seen (one agent's conclusions without its trace mislead the next).
    public static func digest(_ observations: String, limit: Int = 700) -> String {
        var text = observations
            .replacingOccurrences(of: "\\n", with: " ⏎ ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
        text = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined(separator: " ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? "…" + String(text.suffix(limit)) : text
    }
}

public enum StepBudget {
    /// A warning to inject as the run nears its iteration limit, once per threshold.
    public static func warning(iteration: Int, max: Int) -> (id: Int, text: String)? {
        guard max >= 6 else { return nil }
        let used = Double(iteration) / Double(max)
        if used >= 0.9 {
            return (2, "Only \(max - iteration) step(s) left. Stop exploring. Call finish_task NOW with what you verified and what is still open; a partial, honest result is better than none.")
        }
        if used >= 0.75 {
            return (1, "You have used \(iteration) of \(max) steps. Start wrapping up: finish within the next few steps, and if you cannot complete the task, say exactly what you verified and what remains.")
        }
        return nil
    }
}

// MARK: - the model server going away

/// Ollama restarting, sleeping or crashing shows up as a raw `NSURLErrorDomain -1004` blob. Recognize it, wait for
/// the server briefly, and when it really is down, say so in one sentence.
public enum ModelConnection {
    public static let unreachablePrefix = "(couldn't reach the model server"

    private static let transientCodes: Set<Int> = [
        NSURLErrorCannotConnectToHost,      // -1004 connection refused: server not (yet) listening
        NSURLErrorNetworkConnectionLost,    // -1005 server went away mid-reply
        NSURLErrorTimedOut,                 // -1001
        NSURLErrorCannotFindHost,           // -1003
        NSURLErrorNotConnectedToInternet,   // -1009
        NSURLErrorDNSLookupFailed,          // -1006
        NSURLErrorSecureConnectionFailed,   // -1200
    ]

    /// Connection-level trouble (as opposed to the server answering with an error).
    public static func isConnectionProblem(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, transientCodes.contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isConnectionProblem(underlying) }
        return false
    }

    /// Seconds to wait before each retry. An Ollama restart takes a few seconds; a model load a little longer.
    nonisolated(unsafe) public static var retryDelays: [TimeInterval] = [2, 4, 8]

    public static func friendlyMessage(for error: Error) -> String {
        "\(unreachablePrefix) (Ollama). Check that it's running, then send your message again.)"
    }
}
