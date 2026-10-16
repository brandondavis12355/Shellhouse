import Foundation

// File editing, paged reading, search, background jobs and validate-on-write for the
// sandbox's /workspace. Matches what most open-source agent CLIs converged on (see
// docs/AGENT-CLI-COMPARISON.md): edit a file instead of rewriting it, read in pages,
// search without a shell approval, and keep long commands running in the background.

// MARK: - Read tracking (edit only what you have seen)

/// Remembers what each file looked like when the model last read or wrote it, so an edit
/// is refused if the model never saw the file or it changed since (Qwen Code, Crush).
public final class FileReadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Int] = [:]

    public init() {}

    public enum State: Equatable { case never, stale, fresh }

    public func record(_ path: String, content: String) {
        lock.lock(); defer { lock.unlock() }
        seen[path] = content.hashValue
    }

    public func state(of path: String, current: String) -> State {
        lock.lock(); defer { lock.unlock() }
        guard let hash = seen[path] else { return .never }
        return hash == current.hashValue ? .fresh : .stale
    }
}

// MARK: - Edits

public enum EditMatcher {
    public enum Outcome: Equatable {
        case replaced(String, occurrences: Int, fuzzy: Bool)
        case notFound(hint: String)
        case ambiguous(count: Int)
    }

    /// Replaces `old` with `new` in `content`. Exact match first; then a match that ignores
    /// leading/trailing whitespace on each line (re-indenting `new` to the file's indentation).
    /// `old` must match exactly once unless `replaceAll`.
    public static func apply(to content: String, old: String, new: String, replaceAll: Bool = false) -> Outcome {
        let exact = content.components(separatedBy: old).count - 1
        if exact == 1 || (replaceAll && exact > 1) {
            return .replaced(content.replacingOccurrences(of: old, with: new), occurrences: exact, fuzzy: false)
        }
        if exact > 1 { return .ambiguous(count: exact) }

        // Whitespace-tolerant, line by line.
        var fileLines = content.components(separatedBy: "\n")
        var oldLines = old.components(separatedBy: "\n")
        while oldLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { oldLines.removeFirst() }
        while oldLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { oldLines.removeLast() }
        guard !oldLines.isEmpty, oldLines.count <= fileLines.count else { return .notFound(hint: nearMiss(old, in: content)) }
        let wanted = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }
        var starts: [Int] = []
        for start in 0...(fileLines.count - oldLines.count) {
            if (0..<oldLines.count).allSatisfy({ fileLines[start + $0].trimmingCharacters(in: .whitespaces) == wanted[$0] }) {
                starts.append(start)
            }
        }
        if starts.count > 1, !replaceAll { return .ambiguous(count: starts.count) }
        guard !starts.isEmpty else { return .notFound(hint: nearMiss(old, in: content)) }

        let oldIndent = leadingWhitespace(oldLines[0])
        for start in starts.reversed() {
            let fileIndent = leadingWhitespace(fileLines[start])
            let replacement = new.isEmpty ? [] : new.components(separatedBy: "\n").map { line -> String in
                line.hasPrefix(oldIndent) ? fileIndent + line.dropFirst(oldIndent.count) : line
            }
            fileLines.replaceSubrange(start..<(start + oldLines.count), with: replacement)
        }
        return .replaced(fileLines.joined(separator: "\n"), occurrences: starts.count, fuzzy: true)
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// The file lines most like the first line of `old`, numbered, so the next try can copy them exactly.
    static func nearMiss(_ old: String, in content: String) -> String {
        let probe = old.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let lines = content.components(separatedBy: "\n")
        guard !probe.isEmpty, !lines.isEmpty else { return "The text to replace was not found." }
        func score(_ line: String) -> Int {
            let a = Set(probe.lowercased().split { !$0.isLetter && !$0.isNumber })
            let b = Set(line.lowercased().split { !$0.isLetter && !$0.isNumber })
            return a.intersection(b).count
        }
        let best = lines.indices.max { score(lines[$0]) < score(lines[$1]) } ?? 0
        guard score(lines[best]) > 0 else { return "The text to replace was not found, and no line looks like its first line. Read the file again." }
        let from = max(0, best - 2), to = min(lines.count - 1, best + 2)
        let excerpt = (from...to).map { "\($0 + 1): \(lines[$0])" }.joined(separator: "\n")
        return "The text to replace was not found. The closest lines in the file are:\n\(excerpt)\nCopy old_text exactly from the file (without the line numbers)."
    }

    /// A few numbered lines around the first difference, so the model can see what changed.
    static func snippet(before: String, after: String) -> String {
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        let first = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        let from = max(0, first - 3), to = min(b.count - 1, first + 6)
        guard from <= to else { return "" }
        return (from...to).map { "\($0 + 1): \(b[$0])" }.joined(separator: "\n")
    }
}

// MARK: - Paged reads

public enum PagedRead {
    public static let defaultCharacterBudget = 12_000   // a typical source file in one read, not four

    /// Lines `offset` (1-based) onward, up to `limit` lines and the character budget, with where to continue.
    public static func page(_ content: String, offset: Int?, limit: Int?, budget: Int = defaultCharacterBudget) -> [String: Any] {
        let lines = content.components(separatedBy: "\n")
        let total = content.hasSuffix("\n") ? lines.count - 1 : lines.count
        let start = max(1, offset ?? 1)
        guard start <= max(total, 1) else {
            return ["error": "offset \(start) is past the end of the file (\(total) lines)"]
        }
        let maxLines = max(1, limit ?? Int.max)
        var used = 0, end = start - 1
        var picked: [String] = []
        while end < total, picked.count < maxLines {
            let line = lines[end]
            if !picked.isEmpty, used + line.count + 1 > budget { break }
            picked.append(line); used += line.count + 1; end += 1
        }
        var out: [String: Any] = ["content": picked.joined(separator: "\n"), "start_line": start, "end_line": end, "total_lines": total]
        if end < total {
            out["next_offset"] = end + 1
            out["note"] = "Showing lines \(start)–\(end) of \(total). Call read_file with offset \(end + 1) to continue. This is not the whole file: before saying something is missing from it, read the rest or use search_files."
        }
        return out
    }
}

// MARK: - Validate on write

public enum SyntaxCheck {
    public enum Verdict: Equatable { case ok, broken(String), unchecked }

    /// Which checker applies to a path, if any.
    static func kind(of path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "json": return "json"
        case "py": return "python"
        case "sh", "bash": return "shell"
        case "yaml", "yml": return "yaml"
        default: return nil
        }
    }

    /// A `,` followed (after whitespace) by `}` or `]`, outside strings.
    static func hasTrailingComma(_ json: String) -> Bool {
        var inString = false, escaped = false, pendingComma = false
        for c in json {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c.isWhitespace { continue }
            if pendingComma, c == "}" || c == "]" { return true }
            pendingComma = c == ","
            if c == "\"" { inString = true }
        }
        return false
    }

    /// Checks `content` as the file at `path` would be parsed. JSON is checked here; Python, shell and
    /// YAML in the sandbox (YAML only if PyYAML is installed there).
    static func check(_ content: String, path: String, sandboxID: String, sandbox: any SandboxProvider) async -> Verdict {
        guard let kind = kind(of: path) else { return .unchecked }
        if kind == "json" {
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ok }
            do { _ = try JSONSerialization.jsonObject(with: Data(content.utf8), options: [.fragmentsAllowed]) }
            catch { return .broken("invalid JSON: \((error as NSError).userInfo["NSDebugDescription"] as? String ?? error.localizedDescription)") }
            // Foundation tolerates trailing commas; strict parsers (Python, many config loaders) don't.
            if hasTrailingComma(content) { return .broken("invalid JSON: trailing comma before } or ]") }
            return .ok
        }
        // One round trip: the content travels inside the command, is checked from a temp file there, and is removed.
        let abs = "/tmp/shellhouse-validate-\(UUID().uuidString.prefix(8)).\((path as NSString).pathExtension)"
        let check: String
        switch kind {
        case "python": check = "python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' \(abs)"
        case "shell": check = "bash -n \(abs)"
        default: check = "python3 -c 'import sys, yaml; list(yaml.safe_load_all(open(sys.argv[1])))' \(abs)"
        }
        let encoded = Data(content.utf8).base64EncodedString()
        let command = "printf %s '\(encoded)' | base64 -d > \(abs) && \(check); rc=$?; rm -f \(abs); exit $rc"
        guard command.utf8.count < 900_000, let result = try? await sandbox.exec(sandboxID, command: command, timeout: 20, env: nil) else { return .unchecked }
        if result.exitCode == 0 { return .ok }
        let message = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "yaml", message.contains("No module named") { return .unchecked }
        return .broken(String(message.replacingOccurrences(of: abs, with: path).suffix(600)))
    }
}

// MARK: - Executors

enum WorkspaceTools {
    static let readFileMaxBytes = 2_000_000
    static let spillThreshold = ObservationPolicy.maxFieldCharacters
    static let jobIDPattern = "^[a-z0-9]{8}$"

    static func readText(_ sandbox: any SandboxProvider, _ sandboxID: String, _ path: String) async throws -> String {
        String(decoding: try await sandbox.readFile(sandboxID, path: path, maxBytes: readFileMaxBytes), as: UTF8.self)
    }

    /// The lines around the one a parser error names ("line 12"), so the model sees what it wrote there.
    static func excerpt(of content: String, near message: String) -> String {
        guard let range = message.range(of: #"line (\d+)"#, options: .regularExpression),
              let number = Int(message[range].dropFirst(5)) else { return "" }
        let lines = content.components(separatedBy: "\n")
        guard number >= 1, number <= lines.count else { return "" }
        let from = max(1, number - 2), to = min(lines.count, number + 1)
        return "\nAs written, lines \(from)–\(to):\n" + (from...to).map { "\($0): \(lines[$0 - 1])" }.joined(separator: "\n")
    }

    /// Rejects a change that breaks a file which parsed before; flags a new file that doesn't parse.
    static func validated(_ new: String, replacing old: String?, path: String,
                          sandboxID: String, sandbox: any SandboxProvider) async -> (reject: String?, warning: String?) {
        let after = await SyntaxCheck.check(new, path: path, sandboxID: sandboxID, sandbox: sandbox)
        guard case .broken(let reported) = after else { return (nil, nil) }
        let why = reported + excerpt(of: new, near: reported)
        if let old {
            let before = await SyntaxCheck.check(old, path: path, sandboxID: sandboxID, sandbox: sandbox)
            if before == .ok {
                return ("Not written: this change would break \(path) (\(why)). The file is unchanged. Fix the problem "
                        + "and try again; don't resubmit the same change.", nil)
            }
            return (nil, "\(path) still doesn't parse: \(why)")
        }
        return (nil, "\(path) doesn't parse yet: \(why)")
    }

    /// The sandbox manager answers a missing file with a bare 500. Say what actually went wrong, so the model looks
    /// for the right path instead of retrying or calling it a server fault.
    static func readFailure(_ error: Error, path: String, sandbox: SandboxProvider, sandboxID: String) async -> String {
        let message = error.localizedDescription
        guard message.contains("(500)") else { return message }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let probe = try? await sandbox.exec(sandboxID, command: "cd /workspace 2>/dev/null; if [ -d \(quoted) ]; then echo dir; "
            + "elif [ -e \(quoted) ]; then echo exists; else echo missing; fi", timeout: 10, env: nil)
        switch probe?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "missing": return "No such file: \(path) (relative paths start in /workspace). Find it with list_files or search_files."
        case "dir": return "\(path) is a directory: use list_files."
        default: return message
        }
    }

    static func executors(tracker: FileReadTracker) -> [String: ToolRegistry.Executor] {
        var out: [String: ToolRegistry.Executor] = [:]

        out["read_file"] = { sandboxID, sandbox, args, _ in
            guard let path = args["path"]?.asString else { return ["error": "read_file requires 'path'"] }
            do {
                let text = try await readText(sandbox, sandboxID, path)
                tracker.record(path, content: text)
                var page = PagedRead.page(text, offset: args["offset"]?.asInt, limit: args["limit"]?.asInt)
                page["path"] = path
                return page
            } catch {
                return ["error": await readFailure(error, path: path, sandbox: sandbox, sandboxID: sandboxID)]
            }
        }

        out["write_file"] = { sandboxID, sandbox, args, _ in
            guard let path = args["path"]?.asString, let content = args["content"]?.asString else {
                return ["error": "write_file requires 'path' and 'content'"]
            }
            // The old version is only needed to judge a syntax check; don't read it otherwise.
            let existing = SyntaxCheck.kind(of: path) == nil ? nil : try? await readText(sandbox, sandboxID, path)
            let (reject, warning) = await validated(content, replacing: existing, path: path, sandboxID: sandboxID, sandbox: sandbox)
            if let reject { return ["error": reject] }
            do {
                try await sandbox.writeFile(sandboxID, path: path, contents: Data(content.utf8))
                tracker.record(path, content: content)
                var result: [String: Any] = ["path": path, "bytes": content.utf8.count]
                if let warning { result["warning"] = warning }
                return result
            } catch {
                return ["error": error.localizedDescription]
            }
        }

        out["edit_file"] = { sandboxID, sandbox, args, _ in
            guard let path = args["path"]?.asString else { return ["error": "edit_file requires 'path'"] }
            // One edit (old_text/new_text), or several at once (edits: [{old_text, new_text}]) applied in order.
            var pairs: [(old: String, new: String)] = []
            if let list = args["edits"]?.value as? [Any] {
                for item in list {
                    guard let dict = item as? [String: Any], let o = dict["old_text"] as? String, let n = dict["new_text"] as? String else {
                        return ["error": "each item in edits needs 'old_text' and 'new_text'"]
                    }
                    pairs.append((o, n))
                }
            }
            if let o = args["old_text"]?.asString, let n = args["new_text"]?.asString { pairs.insert((o, n), at: 0) }
            guard !pairs.isEmpty else { return ["error": "edit_file requires 'old_text' and 'new_text' (or an 'edits' list)"] }
            for (i, pair) in pairs.enumerated() {
                let label = pairs.count > 1 ? "Edit \(i + 1): " : ""
                guard !pair.old.isEmpty else { return ["error": label + "old_text is empty. To create or replace a whole file, use write_file."] }
                guard pair.old != pair.new else { return ["error": label + "old_text and new_text are the same; nothing to change."] }
            }
            let current: String
            do { current = try await readText(sandbox, sandboxID, path) } catch {
                return ["error": "\(error.localizedDescription). To create a new file, use write_file."]
            }
            switch tracker.state(of: path, current: current) {
            case .never: return ["error": "Read \(path) with read_file before editing it, so the edit matches what is really there."]
            case .stale: return ["error": "\(path) changed since you last read it. Read it again, then edit."]
            case .fresh: break
            }
            var updated = current, occurrences = 0, fuzzy = false
            for (i, pair) in pairs.enumerated() {
                let label = pairs.count > 1 ? "Edit \(i + 1) of \(pairs.count) failed and nothing was written: " : ""
                switch EditMatcher.apply(to: updated, old: pair.old, new: pair.new, replaceAll: args["replace_all"]?.asBool ?? false) {
                case .ambiguous(let count):
                    return ["error": label + "old_text matches \(count) places in \(path). Include more surrounding lines so it matches once, or set replace_all to true."]
                case .notFound(let hint):
                    return ["error": label + hint]
                case .replaced(let text, let count, let wasFuzzy):
                    updated = text; occurrences += count; fuzzy = fuzzy || wasFuzzy
                }
            }
            let (reject, warning) = await validated(updated, replacing: current, path: path, sandboxID: sandboxID, sandbox: sandbox)
            if let reject { return ["error": reject] }
            do {
                try await sandbox.writeFile(sandboxID, path: path, contents: Data(updated.utf8))
            } catch {
                return ["error": error.localizedDescription]
            }
            tracker.record(path, content: updated)
            var result: [String: Any] = ["path": path, "replacements": occurrences, "snippet": EditMatcher.snippet(before: current, after: updated)]
            if fuzzy { result["note"] = "Matched ignoring indentation/whitespace differences; check the snippet." }
            if let warning { result["warning"] = warning }
            return result
        }

        out["search_files"] = { sandboxID, sandbox, args, _ in
            guard let pattern = args["pattern"]?.asString, !pattern.isEmpty else { return ["error": "search_files requires 'pattern'"] }
            let root: String
            do { root = try sandbox.safeRelativePath(args["path"]?.asString ?? ".") } catch { return ["error": "\(error.localizedDescription) (search stays inside /workspace)"] }
            let maxResults = min(max(args["max_results"]?.asInt ?? 50, 1), 200)
            var command = "cd /workspace && grep -rnI --exclude-dir=.shellhouse --exclude-dir=.git --exclude-dir=node_modules -E"
            if let glob = args["file_glob"]?.asString, !glob.isEmpty { command += " --include=\(shellQuote(glob))" }
            command += " -e \(shellQuote(pattern)) -- \(shellQuote(root.isEmpty ? "." : root)) | head -n \(maxResults + 1)"
            guard let result = try? await sandbox.exec(sandboxID, command: command, timeout: 30, env: nil) else { return ["error": "search failed to run"] }
            if result.exitCode > 1, !result.stderr.isEmpty { return ["error": String(result.stderr.prefix(400))] }
            var lines = result.stdout.split(separator: "\n").map { String($0.prefix(240)) }
            var out: [String: Any] = [:]
            if lines.count > maxResults {
                lines = Array(lines.prefix(maxResults))
                out["note"] = "More than \(maxResults) matches; showing the first \(maxResults). Narrow the pattern, path or file_glob."
            }
            out["matches"] = lines
            out["count"] = lines.count
            return out
        }

        out["find_files"] = { sandboxID, sandbox, args, _ in
            guard let pattern = args["pattern"]?.asString, !pattern.isEmpty else { return ["error": "find_files requires 'pattern', e.g. \"*.py\""] }
            let root: String
            do { root = try sandbox.safeRelativePath(args["path"]?.asString ?? ".") } catch { return ["error": "\(error.localizedDescription) (search stays inside /workspace)"] }
            let limit = 200
            let command = "cd /workspace && find \(shellQuote(root.isEmpty ? "." : root)) -type f -name \(shellQuote(pattern))"
                + " -not -path '*/.shellhouse/*' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | sort | head -n \(limit + 1)"
            guard let result = try? await sandbox.exec(sandboxID, command: command, timeout: 30, env: nil) else { return ["error": "find failed to run"] }
            var files = result.stdout.split(separator: "\n").map { String($0).replacingOccurrences(of: "^\\./", with: "", options: .regularExpression) }
            var out: [String: Any] = [:]
            if files.count > limit { files = Array(files.prefix(limit)); out["note"] = "More than \(limit) files; narrow the pattern or path." }
            out["files"] = files
            out["count"] = files.count
            return out
        }

        out["check_job"] = { sandboxID, sandbox, args, _ in
            guard let id = args["job_id"]?.asString, id.range(of: jobIDPattern, options: .regularExpression) != nil else {
                return ["error": "check_job requires the job_id run_shell returned"]
            }
            let lines = min(max(args["tail_lines"]?.asInt ?? 40, 1), 400)
            let wait = min(max(args["wait_seconds"]?.asInt ?? 0, 0), 110)
            let dir = "/workspace/.shellhouse/jobs/\(id)"
            // Optionally wait (up to `wait` seconds) for the job to finish, instead of the model polling.
            let waitLoop = wait > 0 ? "i=0; while [ $i -lt \(wait) ] && [ ! -f \(dir)/exit ] && kill -0 \"$(cat \(dir)/pid 2>/dev/null)\" 2>/dev/null; do sleep 1; i=$((i+1)); done; " : ""
            let command = "test -d \(dir) || { echo NOJOB; exit 0; }; " + waitLoop
                + "if [ -f \(dir)/exit ]; then echo \"EXIT $(cat \(dir)/exit)\"; "
                + "elif [ ! -s \(dir)/pid ] || kill -0 \"$(cat \(dir)/pid)\" 2>/dev/null; then echo RUNNING; else echo GONE; fi; "
                + "tail -n \(lines) \(dir)/log 2>/dev/null"
            guard let result = try? await sandbox.exec(sandboxID, command: command, timeout: TimeInterval(wait + 20), env: nil) else { return ["error": "could not read the job"] }
            let parts = result.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let state = parts.first ?? ""
            if state == "NOJOB" { return ["error": "no job \(id)"] }
            var out: [String: Any] = ["job_id": id, "output_tail": parts.count > 1 ? parts[1] : "", "log": "\(dir)/log"]
            if state.hasPrefix("EXIT ") {
                out["running"] = false
                out["exit_code"] = Int(state.dropFirst(5)) ?? -1
            } else {
                out["running"] = state == "RUNNING"
                if state == "GONE" { out["note"] = "The job stopped without recording an exit code (killed or crashed)." }
            }
            return out
        }

        out["stop_job"] = { sandboxID, sandbox, args, _ in
            guard let id = args["job_id"]?.asString, id.range(of: jobIDPattern, options: .regularExpression) != nil else {
                return ["error": "stop_job requires the job_id run_shell returned"]
            }
            let dir = "/workspace/.shellhouse/jobs/\(id)"
            let command = "pid=$(cat \(dir)/pid 2>/dev/null) || { echo NOJOB; exit 0; }; kill -TERM -- -\"$pid\" 2>/dev/null || kill -TERM \"$pid\" 2>/dev/null; "
                + "sleep 1; kill -0 \"$pid\" 2>/dev/null && kill -KILL -- -\"$pid\" 2>/dev/null; echo STOPPED"
            guard let result = try? await sandbox.exec(sandboxID, command: command, timeout: 20, env: nil) else { return ["error": "could not stop the job"] }
            return result.stdout.contains("NOJOB") ? ["error": "no job \(id)"] : ["job_id": id, "stopped": true]
        }

        return out
    }

    /// Wraps a command so it keeps running after this call returns, with its output in a log file.
    static func backgroundCommand(_ command: String, jobID: String) -> String {
        let dir = "/workspace/.shellhouse/jobs/\(jobID)"
        let inner = "cd /workspace && { \(command)\n}; echo $? > \(dir)/exit"
        // `mkdir` is its own statement: in `a && b & c`, the `&` backgrounds `a && b`, so the pid
        // file could be written before its folder existed.
        return "mkdir -p \(dir) || exit 1; setsid nohup bash -c \(shellQuote(inner)) > \(dir)/log 2>&1 < /dev/null & echo $! > \(dir)/pid; echo started"
    }

    static func newJobID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    /// Saves the full text of an output field that's too long to show, so nothing is lost.
    static func spill(_ text: String, field: String, sandboxID: String, sandbox: any SandboxProvider) async -> String? {
        guard text.count > spillThreshold else { return nil }
        let name = ".shellhouse/output/\(Int(Date().timeIntervalSince1970))-\(newJobID())-\(field).txt"
        guard (try? await sandbox.writeFile(sandboxID, path: name, contents: Data(text.utf8))) != nil else { return nil }
        return "/workspace/\(name)"
    }
}
