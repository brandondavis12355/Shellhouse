import Foundation

// Static analysis of a shell command string, for the guardrail policy.
//
// This is a *conservative lexer/parser*, not a shell. Its one job is to turn
// the text the model produced into: the simple commands that would run
// (including ones hidden inside `$(...)`, backticks, `sh -c '...'`, `eval`,
// `xargs`, `find -exec`, `sudo`/`env`/`nohup` wrappers), their literal
// words with quoting and ANSI-C escapes (`$'\x72\x6d'`) resolved, and flags
// for everything it could NOT resolve statically. Anything unresolved is
// reported as such so the policy can treat it as unknown (ask / deny), never
// as safe. The parser never executes anything.

public struct ShellRedirect: Sendable, Equatable {
    public let op: String
    public let target: String?
    public let targetIsDynamic: Bool
}

public struct ShellCommand: Sendable {
    /// Literal text of each word, quotes removed. A word containing an
    /// expansion keeps its raw text and is flagged in `dynamic`.
    public var words: [String] = []
    public var dynamic: [Bool] = []
    public var assignments: [String] = []
    public var redirects: [ShellRedirect] = []
    /// Wrappers that were peeled off to reach this command (`sudo`, `env`...).
    public var wrappers: [String] = []
    /// Reached through `xargs` (its real arguments are supplied at run time).
    public var viaXargs = false
    /// Appeared inside a `find -exec`/`-ok` payload.
    public var viaFindExec = false

    public var program: String? { words.first }
    public var programIsDynamic: Bool { dynamic.first ?? false }
    public var args: [String] { Array(words.dropFirst()) }
    public var argsAreDynamic: Bool { dynamic.dropFirst().contains(true) }
}

public struct ShellAnalysis: Sendable {
    /// Every simple command that could run, flattened (nested bodies and
    /// unwrapped wrappers included).
    public var commands: [ShellCommand] = []
    public var connectors: [String] = []
    public var hasCommandSubstitution = false
    public var hasProcessSubstitution = false
    public var hasArithmetic = false
    public var hasHeredoc = false
    public var runsInBackground = false
    public var hasSubshellOrGroup = false
    public var hasFunctionDefinition = false
    public var hasControlFlow = false
    public var hasPipe = false
    /// Could not be fully understood (unterminated quote, unbalanced
    /// parenthesis, oversized, too deeply nested, dynamic program name...).
    public var unresolved: [String] = []
    /// Code the model supplied that is invisible here (dynamic command name,
    /// payload on stdin, computed `-c` string). Stricter than `unresolved`.
    public var opaque: [String] = []

    public var isFullyResolved: Bool { unresolved.isEmpty && opaque.isEmpty }
}

public enum ShellAnalyzer {
    static let maxLength = 20_000
    static let maxDepth = 4

    /// Environment the lexer may substitute statically.
    public struct Environment: Sendable {
        public var home: String
        public var cwd: String
        public init(home: String = "/home/box", cwd: String = "/workspace") {
            self.home = home
            self.cwd = cwd
        }
    }

    public static func analyze(_ command: String, environment: Environment = Environment()) -> ShellAnalysis {
        var analysis = ShellAnalysis()
        guard command.utf8.count <= maxLength else {
            analysis.unresolved.append("command longer than \(maxLength) bytes")
            return analysis
        }
        var lexer = Lexer(command.unicodeScalars.map { Character($0) }, environment: environment, depth: 0)
        lexer.run()
        analysis = lexer.analysis
        return analysis
    }

    // MARK: - Lexer

    private struct Word {
        var text = ""
        var dynamic = false
        var hasGlob = false
        var hasBrace = false
        var quotedAny = false
        var isEmpty: Bool { text.isEmpty && !quotedAny }
    }

    private struct Lexer {
        let chars: [Character]
        let environment: Environment
        let depth: Int
        var i = 0
        var analysis = ShellAnalysis()

        // Current simple command being assembled.
        var current = ShellCommand()
        var word = Word()
        var pendingRedirect: String?
        var atCommandStart = true

        init(_ chars: [Character], environment: Environment, depth: Int) {
            self.chars = chars
            self.environment = environment
            self.depth = depth
        }

        mutating func run() {
            while i < chars.count {
                let c = chars[i]
                switch c {
                case " ", "\t":
                    endWord(); i += 1
                case "\n", "\r":
                    endWord(); endCommand(connector: ";"); i += 1
                case "\\":
                    handleBackslash()
                case "'":
                    singleQuote()
                case "\"":
                    doubleQuote()
                case "`":
                    backtick(inDouble: false)
                case "$":
                    dollar(inDouble: false)
                case "#":
                    if word.isEmpty { skipComment() } else { word.text.append(c); i += 1 }
                case ";", "&", "|", "(", ")", "<", ">":
                    operatorToken()
                case "*", "?", "[":
                    word.hasGlob = true; word.text.append(c); i += 1
                case "{":
                    if word.isEmpty && atCommandStart { reservedBrace() } else { brace() }
                case "}":
                    if word.isEmpty && atCommandStart { analysis.hasSubshellOrGroup = true; i += 1 } else { word.text.append(c); i += 1 }
                case "~":
                    tilde()
                default:
                    word.text.append(c); i += 1
                }
            }
            endWord()
            endCommand(connector: nil)
            postProcess()
        }

        // MARK: pieces

        mutating func appendDynamic(_ raw: String) {
            word.text += raw
            word.dynamic = true
        }

        mutating func handleBackslash() {
            if i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "\n" { i += 2; return }          // line continuation
                word.text.append(next)
                word.quotedAny = true
                i += 2
            } else {
                i += 1
            }
        }

        mutating func singleQuote() {
            word.quotedAny = true
            i += 1
            while i < chars.count, chars[i] != "'" {
                word.text.append(chars[i]); i += 1
            }
            if i >= chars.count { analysis.unresolved.append("unterminated single quote") } else { i += 1 }
        }

        mutating func doubleQuote() {
            word.quotedAny = true
            i += 1
            while i < chars.count, chars[i] != "\"" {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    let n = chars[i + 1]
                    if "$`\"\\\n".contains(n) { if n != "\n" { word.text.append(n) }; i += 2 } else { word.text.append(c); i += 1 }
                } else if c == "$" {
                    dollar(inDouble: true)
                } else if c == "`" {
                    backtick(inDouble: true)
                } else {
                    word.text.append(c); i += 1
                }
            }
            if i >= chars.count { analysis.unresolved.append("unterminated double quote") } else { i += 1 }
        }

        mutating func tilde() {
            // Tilde expansion only at the start of a word.
            if word.isEmpty {
                var j = i + 1
                var user = ""
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "-" {
                    user.append(chars[j]); j += 1
                }
                if user.isEmpty {
                    word.text += environment.home
                    i = j
                    return
                }
                appendDynamic("~" + user)   // ~otheruser: unknown home
                i = j
                return
            }
            word.text.append("~"); i += 1
        }

        mutating func brace() {
            // Unquoted `{`: brace expansion can build any word (`{r,}m`).
            var j = i
            var depth = 0
            var hasComma = false
            var hasRange = false
            while j < chars.count {
                if chars[j] == "{" { depth += 1 }
                if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                if chars[j] == "," && depth == 1 { hasComma = true }
                if chars[j] == ".", j + 1 < chars.count, chars[j + 1] == "." { hasRange = true }
                if chars[j] == " " || chars[j] == "\n" || chars[j] == ";" { break }
                j += 1
            }
            if j < chars.count, chars[j] == "}", hasComma || hasRange {
                let raw = String(chars[i...j])
                appendDynamic(raw)
                word.hasBrace = true
                i = j + 1
            } else {
                word.text.append("{"); i += 1
            }
        }

        mutating func reservedBrace() {
            // `{ cmd; }` group at command start.
            if i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" {
                analysis.hasSubshellOrGroup = true
                i += 1
            } else {
                brace()
            }
        }

        mutating func skipComment() {
            while i < chars.count, chars[i] != "\n" { i += 1 }
        }

        /// Grabs text up to the matching close for `$(`/`(`-style nesting,
        /// respecting quotes. Returns nil if unbalanced.
        func matchingClose(from start: Int, open: Character, close: Character) -> Int? {
            var depth = 1
            var j = start
            var quote: Character?
            while j < chars.count {
                let c = chars[j]
                if let q = quote {
                    if c == "\\" && q == "\"" { j += 2; continue }
                    if c == q { quote = nil }
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == "\\" {
                    j += 2; continue
                } else if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { return j }
                }
                j += 1
            }
            return nil
        }

        mutating func dollar(inDouble: Bool) {
            // chars[i] == "$"
            guard i + 1 < chars.count else { word.text.append("$"); i += 1; return }
            let n = chars[i + 1]
            if n == "(" {
                if i + 2 < chars.count, chars[i + 2] == "(" {
                    // arithmetic $(( ... ))
                    analysis.hasArithmetic = true
                    if let end = matchingClose(from: i + 2, open: "(", close: ")") {
                        appendDynamic(String(chars[i...min(end + 1, chars.count - 1)]))
                        i = min(end + 2, chars.count)
                    } else {
                        analysis.unresolved.append("unterminated arithmetic expansion")
                        i = chars.count
                    }
                    return
                }
                analysis.hasCommandSubstitution = true
                if let end = matchingClose(from: i + 2, open: "(", close: ")") {
                    let inner = String(chars[(i + 2)..<end])
                    nestedAnalyze(inner)
                    appendDynamic("$(" + inner + ")")
                    i = end + 1
                } else {
                    analysis.unresolved.append("unterminated command substitution")
                    i = chars.count
                }
            } else if n == "{" {
                if let end = matchingClose(from: i + 2, open: "{", close: "}") {
                    let inner = String(chars[(i + 2)..<end])
                    if inner == "HOME" { word.text += environment.home }
                    else if inner == "PWD" { word.text += environment.cwd }
                    else { appendDynamic("${" + inner + "}") }
                    i = end + 1
                } else {
                    analysis.unresolved.append("unterminated parameter expansion")
                    i = chars.count
                }
            } else if n == "'" && !inDouble {
                ansiCQuote()
            } else if n == "\"" && !inDouble {
                i += 1   // $"..." locale string: same as "..."
                doubleQuote()
            } else if n.isLetter || n == "_" {
                var j = i + 1
                var name = ""
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    name.append(chars[j]); j += 1
                }
                if name == "HOME" { word.text += environment.home }
                else if name == "PWD" { word.text += environment.cwd }
                else { appendDynamic("$" + name) }
                i = j
            } else if n == "?" {
                // `$?` is just the previous exit status (a small integer): harmless as an argument, and
                // `echo "exit=$?"` is how models report results. Not treated as a run-time computed value.
                word.text += "0"
                i += 2
            } else if n.isNumber || "!$#@*-".contains(n) {
                appendDynamic("$" + String(n))
                i += 2
            } else {
                word.text.append("$"); i += 1
            }
        }

        mutating func ansiCQuote() {
            // $'...' — resolve escapes so `$'\x72\x6d'` is seen as "rm".
            word.quotedAny = true
            i += 2
            while i < chars.count, chars[i] != "'" {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    let n = chars[i + 1]
                    switch n {
                    case "n": word.text.append("\n"); i += 2
                    case "t": word.text.append("\t"); i += 2
                    case "r": word.text.append("\r"); i += 2
                    case "a", "b", "f", "v": i += 2
                    case "e", "E": word.text.append("\u{1B}"); i += 2
                    case "\\", "'", "\"", "?": word.text.append(n); i += 2
                    case "x":
                        var hex = ""
                        var j = i + 2
                        while j < chars.count, hex.count < 2, chars[j].isHexDigit { hex.append(chars[j]); j += 1 }
                        if let v = UInt8(hex, radix: 16) { word.text.append(Character(UnicodeScalar(v))) } else { word.dynamic = true }
                        i = j
                    case "u", "U":
                        var hex = ""
                        var j = i + 2
                        let limit = n == "u" ? 4 : 8
                        while j < chars.count, hex.count < limit, chars[j].isHexDigit { hex.append(chars[j]); j += 1 }
                        if let v = UInt32(hex, radix: 16), let s = UnicodeScalar(v) { word.text.append(Character(s)) } else { word.dynamic = true }
                        i = j
                    case "0"..."7":
                        var oct = ""
                        var j = i + 1
                        while j < chars.count, oct.count < 3, ("0"..."7").contains(chars[j]) { oct.append(chars[j]); j += 1 }
                        if let v = UInt8(oct, radix: 8) { word.text.append(Character(UnicodeScalar(v))) } else { word.dynamic = true }
                        i = j
                    default: word.text.append(n); i += 2
                    }
                } else {
                    word.text.append(c); i += 1
                }
            }
            if i >= chars.count { analysis.unresolved.append("unterminated $'...' string") } else { i += 1 }
        }

        mutating func backtick(inDouble: Bool) {
            analysis.hasCommandSubstitution = true
            var j = i + 1
            var inner = ""
            while j < chars.count, chars[j] != "`" {
                if chars[j] == "\\", j + 1 < chars.count { inner.append(chars[j + 1]); j += 2; continue }
                inner.append(chars[j]); j += 1
            }
            if j >= chars.count {
                analysis.unresolved.append("unterminated backtick substitution")
                i = chars.count
                return
            }
            nestedAnalyze(inner)
            appendDynamic("`" + inner + "`")
            i = j + 1
        }

        mutating func nestedAnalyze(_ inner: String) {
            guard depth < ShellAnalyzer.maxDepth else {
                analysis.unresolved.append("nesting deeper than \(ShellAnalyzer.maxDepth)")
                return
            }
            var sub = Lexer(inner.unicodeScalars.map { Character($0) }, environment: environment, depth: depth + 1)
            sub.run()
            merge(sub.analysis)
        }

        mutating func merge(_ other: ShellAnalysis) {
            analysis.commands += other.commands
            analysis.unresolved += other.unresolved
            analysis.opaque += other.opaque
            analysis.hasCommandSubstitution = analysis.hasCommandSubstitution || other.hasCommandSubstitution
            analysis.hasProcessSubstitution = analysis.hasProcessSubstitution || other.hasProcessSubstitution
            analysis.hasArithmetic = analysis.hasArithmetic || other.hasArithmetic
            analysis.hasHeredoc = analysis.hasHeredoc || other.hasHeredoc
            analysis.runsInBackground = analysis.runsInBackground || other.runsInBackground
            analysis.hasSubshellOrGroup = analysis.hasSubshellOrGroup || other.hasSubshellOrGroup
            analysis.hasFunctionDefinition = analysis.hasFunctionDefinition || other.hasFunctionDefinition
            analysis.hasControlFlow = analysis.hasControlFlow || other.hasControlFlow
            analysis.hasPipe = analysis.hasPipe || other.hasPipe
        }

        mutating func operatorToken() {
            endWord()
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case ";":
                endCommand(connector: ";"); i += 1
                if next == ";" { i += 1 }
            case "&":
                if next == "&" { endCommand(connector: "&&"); i += 2 }
                else if next == ">" {
                    // &> and &>> redirect both streams
                    var op = "&>"; i += 2
                    if i < chars.count, chars[i] == ">" { op = "&>>"; i += 1 }
                    pendingRedirect = op
                } else {
                    analysis.runsInBackground = true
                    endCommand(connector: "&"); i += 1
                }
            case "|":
                analysis.hasPipe = true
                if next == "|" { endCommand(connector: "||"); i += 2 }
                else if next == "&" { endCommand(connector: "|&"); i += 2 }
                else { endCommand(connector: "|"); i += 1 }
            case "(":
                if next == "(" {
                    analysis.hasArithmetic = true
                    if let end = matchingClose(from: i + 1, open: "(", close: ")") { i = min(end + 2, chars.count) } else { analysis.unresolved.append("unterminated (( ))"); i = chars.count }
                } else {
                    // Subshell, or a function definition `name() { ... }`.
                    if current.words.count == 1, word.isEmpty, next == ")" {
                        analysis.hasFunctionDefinition = true
                        current = ShellCommand()
                        atCommandStart = true
                        i += 2
                    } else {
                        analysis.hasSubshellOrGroup = true
                        endCommand(connector: "(")
                        i += 1
                    }
                }
            case ")":
                endCommand(connector: ")"); i += 1
            case "<":
                if next == "(" {
                    analysis.hasProcessSubstitution = true
                    if let end = matchingClose(from: i + 2, open: "(", close: ")") {
                        let inner = String(chars[(i + 2)..<end])
                        nestedAnalyze(inner)
                        appendDynamic("<(" + inner + ")")
                        i = end + 1
                    } else { analysis.unresolved.append("unterminated process substitution"); i = chars.count }
                } else if next == "<" {
                    analysis.hasHeredoc = true
                    var op = "<<"; i += 2
                    if i < chars.count, chars[i] == "<" { op = "<<<"; i += 1 }
                    if i < chars.count, chars[i] == "-" { op += "-"; i += 1 }
                    pendingRedirect = op
                } else if next == "&" {
                    pendingRedirect = "<&"; i += 2
                } else {
                    pendingRedirect = "<"; i += 1
                }
            case ">":
                if next == "(" {
                    analysis.hasProcessSubstitution = true
                    if let end = matchingClose(from: i + 2, open: "(", close: ")") {
                        let inner = String(chars[(i + 2)..<end])
                        nestedAnalyze(inner)
                        appendDynamic(">(" + inner + ")")
                        i = end + 1
                    } else { analysis.unresolved.append("unterminated process substitution"); i = chars.count }
                } else if next == ">" {
                    pendingRedirect = ">>"; i += 2
                } else if next == "&" {
                    pendingRedirect = ">&"; i += 2
                } else if next == "|" {
                    pendingRedirect = ">|"; i += 2
                } else {
                    pendingRedirect = ">"; i += 1
                }
            default:
                i += 1
            }
        }

        // MARK: words and commands

        mutating func endWord() {
            guard !word.isEmpty else { word = Word(); return }
            defer { word = Word() }
            let text = word.text
            let dynamic = word.dynamic || word.hasBrace

            if let op = pendingRedirect {
                pendingRedirect = nil
                // `2>` style fd prefix lands in the previous word; ignore it.
                current.redirects.append(ShellRedirect(op: op, target: text, targetIsDynamic: dynamic || word.hasGlob))
                if op.hasPrefix("<<") { /* here-doc delimiter / here-string */ }
                return
            }
            // fd number immediately before a redirect operator (`2>file`) was
            // consumed as a word; handled by dropping pure-digit words that
            // are followed by a redirect in `endCommand` heuristics — keep simple:
            if atCommandStart, current.words.isEmpty,
               let eq = text.firstIndex(of: "="), eq != text.startIndex,
               text[text.startIndex..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
               !word.quotedAny {
                current.assignments.append(text)
                return
            }
            if expectFunctionName, current.words.isEmpty {
                expectFunctionName = false
                atCommandStart = true
                return
            }
            if current.words.isEmpty, afterTime, (text == "-p" || text == "--"), !word.quotedAny { return }
            afterTime = false
            if current.words.isEmpty {
                if Self.reservedWords.contains(text), !word.quotedAny, !dynamic {
                    handleReserved(text)
                    return
                }
            }
            current.words.append(text)
            current.dynamic.append(dynamic)
            atCommandStart = false
        }

        static let reservedWords: Set<String> = [
            "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac",
            "in", "select", "function", "!", "time", "coproc", "[[", "]]",
        ]

        mutating func handleReserved(_ w: String) {
            switch w {
            case "then", "else", "elif", "do", "!", "time", "coproc", "in":
                // Keywords that precede a command; the command after them is
                // recorded normally.
                analysis.hasControlFlow = analysis.hasControlFlow || (w != "!" && w != "time")
            case "fi", "done", "esac":
                analysis.hasControlFlow = true
            case "if", "while", "until":
                analysis.hasControlFlow = true
            case "function":
                break
            case "for", "select", "case":
                analysis.hasControlFlow = true
                // The loop header / case word is not a command: swallow to the
                // next connector by marking this command as non-executing.
                current.words = []
                current.dynamic = []
                skipHeader = true
            default:
                analysis.hasControlFlow = true
            }
            if w == "function" { analysis.hasFunctionDefinition = true; expectFunctionName = true }
            if w == "time" { afterTime = true }
        }

        var skipHeader = false
        var afterTime = false
        var expectFunctionName = false

        mutating func endCommand(connector: String?) {
            endWord()
            if skipHeader {
                // Drop the words of a `for x in ...`/`case x in` header.
                current = ShellCommand()
                skipHeader = false
            }
            if !current.words.isEmpty || !current.redirects.isEmpty || !current.assignments.isEmpty {
                finish(current)
            }
            current = ShellCommand()
            pendingRedirect = nil
            atCommandStart = true
            if let connector { analysis.connectors.append(connector) }
        }

        mutating func finish(_ command: ShellCommand) {
            var command = command
            // `2>file` — a bare fd number before the operator was parsed as a
            // word; drop trailing pure-digit words when the command has redirects.
            if !command.redirects.isEmpty, let last = command.words.last, last.allSatisfy(\.isNumber), command.words.count > 1 {
                command.words.removeLast(); command.dynamic.removeLast()
            }
            guard !command.words.isEmpty else {
                if !command.redirects.isEmpty || !command.assignments.isEmpty { analysis.commands.append(command) }
                return
            }
            unwrap(command, depth: depth)
        }

        // MARK: wrappers

        static let simpleWrappers: Set<String> = [
            "sudo", "doas", "nohup", "nice", "ionice", "time", "command", "builtin", "exec", "stdbuf", "setsid",
            "env", "timeout", "unbuffer", "chronic", "flock", "strace", "ltrace", "watch", "chroot", "busybox", "script",
        ]
        static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "ash"]

        mutating func unwrap(_ command: ShellCommand, depth: Int) {
            analysis.commands.append(command)
            guard let program = command.program, !command.programIsDynamic else {
                if command.programIsDynamic { analysis.opaque.append("dynamic command name") }
                return
            }
            let name = Self.baseName(program)
            let args = command.args
            let argDyn = Array(command.dynamic.dropFirst())

            if Self.shells.contains(name) {
                if let idx = args.firstIndex(where: { $0 == "-c" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") && $0.count <= 4) }),
                   idx + 1 < args.count {
                    if argDyn[idx + 1] { analysis.opaque.append("\(name) -c with a dynamic payload"); return }
                    nestedAnalyze(args[idx + 1])
                } else if args.isEmpty || args.allSatisfy({ $0.hasPrefix("-") }) {
                    if let hs = command.redirects.first(where: { $0.op == "<<<" && !$0.targetIsDynamic }), let t = hs.target {
                        nestedAnalyze(t)
                    } else {
                        analysis.opaque.append("\(name) reading commands from stdin")
                    }
                } else if let script = args.first(where: { !$0.hasPrefix("-") }) {
                    analysis.unresolved.append("\(name) running script \(script)")
                }
                return
            }
            if name == "trap", let payload = args.first(where: { !$0.hasPrefix("-") }) {
                let idx = args.firstIndex(of: payload) ?? 0
                if argDyn[idx] { analysis.opaque.append("trap with a dynamic handler") } else { nestedAnalyze(payload) }
                return
            }
            if name == "eval" {
                if argDyn.contains(true) { analysis.opaque.append("eval of a dynamic string"); return }
                nestedAnalyze(args.joined(separator: " "))
                return
            }
            if name == "xargs" {
                // First non-option word starts the command xargs will run.
                var k = 0
                let withValue: Set<String> = ["-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "--max-args", "--max-procs", "--delimiter", "--arg-file", "--replace"]
                while k < args.count, args[k].hasPrefix("-") {
                    k += withValue.contains(args[k]) ? 2 : 1
                }
                if k < args.count {
                    var inner = ShellCommand()
                    inner.words = Array(args[k...])
                    inner.dynamic = Array(argDyn[k...])
                    inner.viaXargs = true
                    inner.wrappers = command.wrappers + ["xargs"]
                    unwrap(inner, depth: depth)
                } else {
                    analysis.unresolved.append("xargs with no command")
                }
                return
            }
            if name == "find" {
                var k = 0
                while k < args.count {
                    if ["-exec", "-execdir", "-ok", "-okdir"].contains(args[k]) {
                        var payload: [String] = []
                        var payloadDyn: [Bool] = []
                        k += 1
                        while k < args.count, args[k] != ";", args[k] != "+", args[k] != "\\;" {
                            payload.append(args[k]); payloadDyn.append(argDyn[k]); k += 1
                        }
                        if !payload.isEmpty {
                            var inner = ShellCommand()
                            inner.words = payload
                            inner.dynamic = payloadDyn
                            inner.viaFindExec = true
                            inner.wrappers = command.wrappers + ["find"]
                            unwrap(inner, depth: depth)
                        }
                    }
                    k += 1
                }
                return
            }
            // `command -v gh` / `command -V gh` only LOOK UP a program; they run nothing. Peeling them would turn the
            // lookup into a call of the program itself (with the option dropped), so they stay a plain command.
            if name == "command", let first = args.first, first.hasPrefix("-"), first.dropFirst().allSatisfy({ "pvV".contains($0) }), first.contains("v") || first.contains("V") {
                return
            }
            if Self.simpleWrappers.contains(name) {
                // Skip the wrapper's own options/assignments to find the command.
                var k = 0
                let optsWithValue: [String: Set<String>] = [
                    "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U"],
                    "doas": ["-u", "-C"],
                    "env": ["-u", "-C", "-S"],
                    "timeout": ["-s", "-k", "--signal", "--kill-after"],
                    "nice": ["-n"], "ionice": ["-c", "-n", "-p"],
                    "stdbuf": ["-i", "-o", "-e"], "strace": ["-o", "-e", "-p", "-s", "-u", "-E", "-a", "-P"], "ltrace": ["-o", "-e", "-p", "-s", "-u", "-a"], "exec": ["-a"], "script": ["-c", "-T", "-I", "-O", "-B", "-E", "-m", "-t"], "flock": ["-w", "-E"], "chroot": [], "watch": ["-n", "-d"],
                ]
                if name == "env" {
                    for (idx, a) in args.enumerated() {
                        if a == "-S" || a == "--split-string", idx + 1 < args.count {
                            if argDyn[idx + 1] { analysis.opaque.append("env -S with a dynamic payload") } else { nestedAnalyze(args[idx + 1]) }
                        } else if a.hasPrefix("--split-string=") {
                            nestedAnalyze(String(a.dropFirst("--split-string=".count)))
                        } else if a.hasPrefix("-S"), a.count > 2 {
                            nestedAnalyze(String(a.dropFirst(2)))
                        }
                    }
                }
                while k < args.count {
                    let a = args[k]
                    if a == "--" { k += 1; break }
                    if a.hasPrefix("-") {
                        k += optsWithValue[name]?.contains(a) == true ? 2 : 1
                        continue
                    }
                    if name == "env", a.contains("=") { k += 1; continue }
                    if name == "timeout" || name == "flock" || name == "chroot" {
                        // first positional is DURATION / lock / newroot
                        k += 1
                    }
                    break
                }
                if k < args.count {
                    var inner = ShellCommand()
                    inner.words = Array(args[k...])
                    inner.dynamic = Array(argDyn[k...])
                    inner.wrappers = command.wrappers + [name]
                    unwrap(inner, depth: depth)
                } else if name != "env" {
                    analysis.unresolved.append("\(name) with no command")
                }
                return
            }
        }

        static func baseName(_ program: String) -> String {
            program.split(separator: "/").last.map(String.init) ?? program
        }

        mutating func postProcess() {
            // A command named by a path is only recognized for standard system
            // directories; everything else is an arbitrary executable.
        }
    }
}

extension ShellAnalyzer {
    static let systemBinDirectories: [String] = [
        "/bin/", "/usr/bin/", "/usr/local/bin/", "/sbin/", "/usr/sbin/", "/usr/local/sbin/",
    ]

    /// The recognizable name for `program`: a bare name, or a standard system
    /// path. `nil` for relative / unusual paths (`./rm`, `/tmp/x/rm`), which
    /// could be anything.
    public static func recognizedName(of program: String) -> String? {
        if !program.contains("/") { return program }
        guard program.hasPrefix("/") else { return nil }
        let normalized = normalize(path: program)
        for dir in systemBinDirectories where normalized.hasPrefix(dir) {
            let rest = String(normalized.dropFirst(dir.count))
            if !rest.contains("/") { return rest }
        }
        return nil
    }

    /// Lexically normalize `path` (collapse `.`/`..`/`//`) against `cwd`.
    /// Does not touch the filesystem, so symlinks are NOT resolved — the
    /// container's own boundary has to cover that.
    public static func normalize(path: String, cwd: String = "/workspace", home: String = "/home/box") -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + "/" + p.dropFirst(2) }
        else if p.hasPrefix("~"), !p.hasPrefix("~+"), !p.hasPrefix("~-") {
            // ~user: assume /home/user (or /root for root).
            let rest = p.dropFirst()
            let user = rest.prefix { $0 != "/" }
            let tail = rest.dropFirst(user.count)
            p = (user == "root" ? "/root" : "/home/" + user) + tail
        }
        if !p.hasPrefix("/") { p = cwd + "/" + p }
        // /proc/<pid>/root is the filesystem root; /proc/<pid>/cwd the cwd.
        // Resolve before ".." collapsing so `/proc/self/cwd/../..` stays honest.
        for _ in 0..<2 {
            p = p.replacingOccurrences(of: #"^/+proc/[^/]+/root(?=/|$)"#, with: "", options: .regularExpression)
            p = p.replacingOccurrences(of: #"^/+proc/[^/]+/cwd(?=/|$)"#, with: cwd, options: .regularExpression)
        }
        if p.isEmpty { p = "/" }
        var parts: [Substring] = []
        for component in p.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}
