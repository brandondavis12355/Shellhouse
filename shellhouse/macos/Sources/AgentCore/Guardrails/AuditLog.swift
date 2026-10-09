import CryptoKit
import Foundation

/// Redacts secret-looking material before anything is logged or shown.
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        #"(?i)\b(api[_-]?key|access[_-]?key|secret|token|passwd|password|authorization)\b\s*[=:]\s*(?:(?:bearer|basic|token)\s+)?\S+"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]{6,}"#,
        #"\bsk-[A-Za-z0-9_\-]{16,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        #"(?i)\bSHELLHOUSE-CANARY-[A-Za-z0-9]+"#,
        #"://[^/\s:@]+:[^/\s@]+@"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String, limit: Int = 300) -> String {
        var out = text
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }
}

/// Append-only, hash-chained record of every guardrail decision. Lives on the
/// Mac (never in the sandbox), so a compromised container can't rewrite it.
/// Each entry commits to the previous entry's hash; `verify()` detects edits,
/// deletions and reordering.
public actor AuditLog {
    public struct Entry: Codable, Sendable, Equatable {
        public var seq: Int
        public var ts: Date
        public var prev: String
        public var bot: String
        public var tool: String
        public var effect: String
        public var verdict: String
        public var outcome: String
        public var rules: [String]
        public var reasons: [String]
        public var tainted: Bool
        public var sources: [String]
        public var preview: String
        public var hash: String
    }

    public struct Verification: Sendable, Equatable {
        public var ok: Bool
        public var entries: Int
        public var firstBadSeq: Int?
        public var detail: String
    }

    public static let genesis = String(repeating: "0", count: 64)
    public static let shared = AuditLog(url: AuditLog.defaultURL())

    private let url: URL
    private let maxBytes: Int
    private var lastHash: String
    private var nextSeq: Int
    private var loaded = false

    public init(url: URL, maxBytes: Int = 8 * 1024 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
        self.lastHash = Self.genesis
        self.nextSeq = 1
    }

    public static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICompute/audit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("audit.jsonl")
    }

    private func loadTail() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let decoder = Self.decoder()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) {
                lastHash = entry.hash
                nextSeq = entry.seq + 1
                return
            }
        }
    }

    @discardableResult
    public func append(
        bot: String, tool: String, effect: String, verdict: String, outcome: String,
        rules: [String], reasons: [String], tainted: Bool, sources: [String], preview: String
    ) -> Entry? {
        loadTail()
        var entry = Entry(
            seq: nextSeq, ts: Date(), prev: lastHash, bot: bot, tool: tool, effect: effect, verdict: verdict,
            outcome: outcome, rules: rules, reasons: reasons.map { Redactor.redact($0, limit: 200) },
            tainted: tainted, sources: sources, preview: Redactor.redact(preview), hash: ""
        )
        entry.hash = Self.hash(of: entry)
        guard var line = try? Self.encoder().encode(entry) else { return nil }
        line.append(UInt8(ascii: "\n"))
        rotateIfNeeded()
        // The log must never silently vanish because its folder is missing.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        lastHash = entry.hash
        nextSeq += 1
        return entry
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archived = url.deletingLastPathComponent().appendingPathComponent("audit-\(stamp).jsonl")
        try? FileManager.default.moveItem(at: url, to: archived)
        // The chain continues across files: the new file's first entry's
        // `prev` is the archived file's last hash (still held in `lastHash`).
    }

    public func entries(limit: Int = 200) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = Self.decoder()
        let all = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        return Array(all.suffix(limit))
    }

    /// Recomputes every hash and checks the chain links.
    public func verify() -> Verification {
        guard let data = try? Data(contentsOf: url) else { return Verification(ok: true, entries: 0, firstBadSeq: nil, detail: "empty") }
        let decoder = Self.decoder()
        var prev: String?
        var count = 0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)) else {
                return Verification(ok: false, entries: count, firstBadSeq: nil, detail: "unreadable line after entry \(count)")
            }
            if let prev, entry.prev != prev {
                return Verification(ok: false, entries: count, firstBadSeq: entry.seq, detail: "chain broken at seq \(entry.seq)")
            }
            if Self.hash(of: entry) != entry.hash {
                return Verification(ok: false, entries: count, firstBadSeq: entry.seq, detail: "entry \(entry.seq) was modified")
            }
            prev = entry.hash
            count += 1
        }
        return Verification(ok: true, entries: count, firstBadSeq: nil, detail: "chain intact")
    }

    static func hash(of entry: Entry) -> String {
        var copy = entry
        copy.hash = ""
        let data = (try? encoder().encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}

/// Short, stable digest of a tool call's arguments, so an approval can be tied
/// to exactly the action the human saw.
public enum ArgsDigest {
    public static func digest(tool: String, arguments: [String: AnyCodable]) -> String {
        let raw = arguments.mapValues(\.value)
        let data = (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])) ?? Data()
        let hash = SHA256.hash(data: Data(tool.utf8) + [0] + data)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
