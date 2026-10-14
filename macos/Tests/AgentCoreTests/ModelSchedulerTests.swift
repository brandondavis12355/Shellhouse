import XCTest
@testable import AgentCore

final class ModelSchedulerTests: XCTestCase {
    private actor Order { var names: [String] = []; func add(_ n: String) { names.append(n) } }

    func testFreeSlotGoesToTheHighestPriorityWaiter() async throws {
        let scheduler = ModelScheduler(slots: 1)
        let order = Order()
        let gate = AsyncStream<Void>.makeStream()
        // Hold the only slot until the waiters have queued.
        let holder = Task { try await scheduler.run(bot: "holder", priority: 0) { for await _ in gate.stream { break } } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let low = Task { try await scheduler.run(bot: "idle", priority: 0) { await order.add("idle") } }
        try await Task.sleep(nanoseconds: 20_000_000)
        let high = Task { try await scheduler.run(bot: "busy", priority: 100) { await order.add("busy") } }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.continuation.yield(); gate.continuation.finish()
        _ = try await (holder.value, low.value, high.value)
        let names = await order.names
        XCTAssertEqual(names, ["busy", "idle"], "the higher priority goes first even though it queued later")
    }

    func testWaitingAddsPrioritySoNobodyStarves() async {
        let scheduler = ModelScheduler(slots: 1)
        let now = Date()
        let oldLow = await scheduler.score(bot: "a", priority: 0, enqueued: now.addingTimeInterval(-60), now: now)
        let newHigh = await scheduler.score(bot: "b", priority: 100, enqueued: now, now: now)
        XCTAssertGreaterThan(oldLow, newHigh, "a minute of waiting beats a fresh high-priority request")
    }

    func testCancelledWaiterDoesNotLeakTheSlot() async throws {
        let scheduler = ModelScheduler(slots: 1)
        let gate = AsyncStream<Void>.makeStream()
        let holder = Task { try await scheduler.run(bot: "holder", priority: 0) { for await _ in gate.stream { break } } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let doomed = Task { try await scheduler.run(bot: "doomed", priority: 0) { } }
        try await Task.sleep(nanoseconds: 20_000_000)
        doomed.cancel()
        _ = try? await doomed.value
        gate.continuation.yield(); gate.continuation.finish()
        try await holder.value
        let snap = await scheduler.snapshot()
        XCTAssertEqual(snap.running, 0)
        XCTAssertTrue(snap.waiting.isEmpty)
        let after = try await scheduler.run(bot: "next", priority: 0) { 42 }
        XCTAssertEqual(after, 42)
    }
}
