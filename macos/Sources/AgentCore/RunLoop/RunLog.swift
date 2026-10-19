import Foundation

/// One thing that happened in a run. The log of these is the run's memory: nothing in it is ever edited, and the
/// prompt the model sees is built from it by `ContextView`. Summaries and drops are events too (`condensed`), so a
/// run can be replayed and audited exactly. See docs/HARNESS-REDESIGN.md section 3.1.
public struct RunEvent: Codable, Sendable, Identifiable {
    public enum Kind: Codable, Sendable {
        /// The fixed start of the prompt. Never changes during a run, which keeps the prompt cache warm.
        case system(String)
        case userMessage(content: String, images: [String]?)
        /// The model's reply, including the tool calls it made (a tool call is part of the reply, not a separate row).
        case modelReply(ChatMessage)
        case toolResult(name: String, content: String)
        /// A screenshot handed to the model as a user turn. Older ones are dropped from the view, not from the log.
        case screenshot(content: String, images: [String])
        /// A correction from a guard. `inContext` is false when it was recorded but not shown to the model (a repeat of
        /// the line above it). `supersedes` names a model reply to leave out of the prompt (an announcement the model
        /// would copy).
        case nudge(kind: String, text: String, escalation: Int, supersedes: Int?, inContext: Bool)
        case condensed(Condensation)
        case verification(command: String, exitCode: Int, output: String)
        case approval(tool: String, outcome: String, detail: String)
        case stateNote(String)
    }

    /// How older context is made smaller, without editing the log.
    public enum Condensation: Codable, Sendable, Equatable {
        /// Everything from event `first` to event `last` (as rendered) is replaced by `text`.
        case summary(first: Int, last: Int, text: String)
        /// Old tool output rendered as a stub, from this point on (see `ObservationPolicy.collapseStale`).
        case collapse(keepLast: Int, minCharacters: Int, batch: Int)
    }

    public let id: Int
    public let time: Date
    /// Which run of the app wrote it: event ids restart at 0 with each runtime.
    public let session: String
    public let kind: Kind

    /// The same event without screenshots: what is written to disk.
    func persistable() -> RunEvent {
        switch kind {
        case .userMessage(let content, let images):
            let omitted = (images ?? []).isEmpty ? nil : (images ?? []).map { "(\($0.count) bytes of image omitted)" }
            return RunEvent(id: id, time: time, session: session, kind: .userMessage(content: content, images: omitted))
        case .modelReply(var message):
            message.images = nil
            return RunEvent(id: id, time: time, session: session, kind: .modelReply(message))
        case .screenshot(let content, let images):
            return RunEvent(id: id, time: time, session: session,
                            kind: .screenshot(content: content, images: images.map { "(\($0.count) bytes of image omitted)" }))
        default:
            return self
        }
    }
}

/// Where a log's events go as they happen (a file, or a test's array).
public protocol RunLogSink: Sendable {
    func write(_ event: RunEvent)
}

/// An append-only list of events. A value type: the runtime owns the one copy and the view reads it.
public struct RunLog: Sendable {
    public private(set) var events: [RunEvent] = []
    public let session: String
    private let sink: (any RunLogSink)?

    public init(sink: (any RunLogSink)? = nil, session: String = String(UUID().uuidString.prefix(8))) {
        self.sink = sink
        self.session = session
    }

    @discardableResult
    public mutating func append(_ kind: RunEvent.Kind, persist: Bool = true) -> RunEvent {
        let event = RunEvent(id: events.count, time: Date(), session: session, kind: kind)
        events.append(event)
        if persist { sink?.write(event) }
        return event
    }

    public var count: Int { events.count }

    /// Reads a log written by `RunLogFileSink`. Lines that don't parse are skipped, so a torn last line loses one event.
    public static func load(from url: URL) -> [RunEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = RunLogCoding.decoder
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(RunEvent.self, from: Data($0)) }
    }
}

enum RunLogCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Writes one JSON object per line, next to the bot's transcript. Off the caller's thread, in order.
/// A file past `maxBytes` is moved aside once at start-up so one bot's log can't grow without bound.
public final class RunLogFileSink: RunLogSink, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "RunLogFileSink", qos: .utility)
    private var handle: FileHandle?

    public init(url: URL, maxBytes: Int = 20_000_000) {
        self.url = url
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("old")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
    }

    public func write(_ event: RunEvent) {
        queue.async { [self] in
            guard var line = try? RunLogCoding.encoder.encode(event.persistable()) else { return }
            line.append(UInt8(ascii: "\n"))
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: line)
        }
    }

    /// Blocks until everything written so far is on disk.
    public func flush() { queue.sync {} }
}
