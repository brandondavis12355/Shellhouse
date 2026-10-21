import Foundation

/// Lets a tool tell the app where the bot's pointer is about to go, before the tool acts. Results are only reported after the
/// action, so without this the on-screen pointer arrived after the click it was meant to show. A tool announces the target, waits
/// `arrival` seconds for the pointer to glide there, then clicks: the screenshot that follows shows a click that landed where
/// the pointer was seen.
public enum PointerBus {
    public typealias Handler = @Sendable (_ x: Int, _ y: Int, _ clicked: Bool) -> Void
    /// Long enough for the pointer's glide (0.45 s) to finish and be seen.
    public static let arrival: TimeInterval = 0.9

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    public static func setHandler(_ handler: Handler?, for sandboxID: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[sandboxID] = handler
    }

    /// Shows the pointer at (x, y) and waits for it to get there. Does nothing, and does not wait, when nothing is watching.
    public static func moveAndWait(sandboxID: String, x: Int, y: Int, clicked: Bool = false) async {
        lock.lock(); let handler = handlers[sandboxID]; lock.unlock()
        guard let handler else { return }
        handler(x, y, clicked)
        try? await Task.sleep(nanoseconds: UInt64(arrival * 1_000_000_000))
    }
}
