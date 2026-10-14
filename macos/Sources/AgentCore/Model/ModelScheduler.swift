import Foundation

/// Decides which bot gets the main model next when more of them want it than there are request slots.
///
/// Every bot shares one local model. Ollama serves requests in arrival order and splits its speed across all of
/// them at once, so a bot the user is waiting on, or one holding up a goal, got no more of the model than an idle
/// bot chatting. Here a limited number of requests run at a time (Settings → Models), and a free slot goes to the
/// waiting request with the highest priority: the bot's own score (see `Bot.modelPriority`), plus how busy it has
/// been in the last 10 minutes, plus time spent waiting (so no bot ever starves).
public actor ModelScheduler {
    public static let shared = ModelScheduler()

    public static let slotsKey = "models.concurrentRequests"
    /// 0 means off: every request goes straight through, the way it worked before.
    public static let slotChoices = [0, 1, 2, 3, 4, 6]
    public static let defaultSlots = 3
    public static var configuredSlots: Int {
        let stored = UserDefaults.standard.object(forKey: slotsKey) as? Int ?? defaultSlots
        return slotChoices.contains(stored) ? stored : defaultSlots
    }

    /// Priority points per second of waiting.
    static let agingPerSecond = 2.0
    /// Busy model seconds in the last 10 minutes, as priority (capped).
    static let utilizationWindow: TimeInterval = 600
    static let maxUtilizationBonus = 20.0

    /// Where long waits are reported (the app sends them to the debug console).
    nonisolated(unsafe) public static var waitLog: (@Sendable (String) -> Void)?

    private struct Waiter {
        let id: UUID
        let bot: String
        let priority: Double
        let enqueued: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private var running = 0
    /// Waiters that were handed a slot (as opposed to woken because they were cancelled).
    private var granted: Set<UUID> = []
    private var waiters: [Waiter] = []
    /// (bot, finished at, seconds the request held a slot)
    private var usage: [(bot: String, at: Date, seconds: Double)] = []
    private let slotsOverride: Int?

    public init(slots: Int? = nil) { slotsOverride = slots }

    private var slots: Int { slotsOverride ?? Self.configuredSlots }

    /// Runs `body` once a slot is free and this request is the most deserving one waiting.
    public func run<T: Sendable>(bot: String, priority: Double, _ body: @Sendable () async throws -> T) async throws -> T {
        let started = Date()
        let id = try await acquire(bot: bot, priority: priority)
        let waited = Date().timeIntervalSince(started)
        if waited > 2 {
            Self.waitLog?("\(bot) waited \(String(format: "%.1f", waited)) s for the model (priority \(Int(priority)), \(waiters.count) still waiting)")
        }
        let began = Date()
        defer { release(id: id, bot: bot, seconds: Date().timeIntervalSince(began)) }
        return try await body()
    }

    /// Effective priority right now: the bot's score, its recent use of the model, and how long it has waited.
    func score(bot: String, priority: Double, enqueued: Date, now: Date = Date()) -> Double {
        let busy = usage.filter { $0.bot == bot && now.timeIntervalSince($0.at) < Self.utilizationWindow }.reduce(0) { $0 + $1.seconds }
        return priority + min(Self.maxUtilizationBonus, busy / 30) + now.timeIntervalSince(enqueued) * Self.agingPerSecond
    }

    private func acquire(bot: String, priority: Double) async throws -> UUID {
        let id = UUID()
        if slots == 0 || (running < slots && waiters.isEmpty) {
            running += 1
            return id
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(Waiter(id: id, bot: bot, priority: priority, enqueued: Date(), continuation: continuation))
                dispatch()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        guard granted.remove(id) != nil else { throw CancellationError() }
        if Task.isCancelled {
            running = max(0, running - 1); dispatch()
            throw CancellationError()
        }
        return id
    }

    private func release(id: UUID, bot: String, seconds: Double) {
        let now = Date()
        usage.append((bot, now, seconds))
        usage.removeAll { now.timeIntervalSince($0.at) > Self.utilizationWindow }
        running = max(0, running - 1)
        dispatch()
    }

    /// The slot count changed in Settings: hand any newly free slots out now instead of at the next release.
    public func settingsChanged() { dispatch() }

    /// Hands free slots to the best waiting requests.
    private func dispatch() {
        let now = Date()
        while !waiters.isEmpty, slots == 0 || running < slots {
            let best = waiters.indices.max { score(bot: waiters[$0].bot, priority: waiters[$0].priority, enqueued: waiters[$0].enqueued, now: now)
                < score(bot: waiters[$1].bot, priority: waiters[$1].priority, enqueued: waiters[$1].enqueued, now: now) }!
            let next = waiters.remove(at: best)
            running += 1
            granted.insert(next.id)
            next.continuation.resume()
        }
    }

    /// A cancelled waiter leaves the queue without a slot. (One already granted gives it back in `acquire`.)
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    /// For the debug console: who holds or waits for the model now.
    public func snapshot() -> (running: Int, slots: Int, waiting: [String]) {
        (running, slots, waiters.map(\.bot))
    }
}

/// A model backend whose requests go through `ModelScheduler`.
public struct ScheduledBackend: ModelBackend {
    let inner: any ModelBackend
    let bot: String
    let scheduler: ModelScheduler
    /// Asked at each request, so the score reflects the bot's work at that moment.
    let priority: @Sendable () async -> Double

    public init(_ inner: any ModelBackend, bot: String, scheduler: ModelScheduler = .shared, priority: @escaping @Sendable () async -> Double) {
        self.inner = inner
        self.bot = bot
        self.scheduler = scheduler
        self.priority = priority
    }

    public var name: String { inner.name }
    public func supportsVision(model: String?) async -> Bool { await inner.supportsVision(model: model) }
    public func availableModels() async throws -> [String] { try await inner.availableModels() }

    public func chat(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double) async throws -> ModelReply {
        let inner = inner
        return try await scheduler.run(bot: bot, priority: await priority()) {
            try await inner.chat(messages: messages, tools: tools, model: model, temperature: temperature)
        }
    }

    public func chatStream(messages: [ChatMessage], tools: [ToolSchema], model: String?, temperature: Double,
                           onDelta: @escaping @Sendable (String) -> Void) async throws -> ModelReply {
        let inner = inner
        return try await scheduler.run(bot: bot, priority: await priority()) {
            try await inner.chatStream(messages: messages, tools: tools, model: model, temperature: temperature, onDelta: onDelta)
        }
    }
}
