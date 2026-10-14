import Foundation

/// A value several threads read and the app occasionally replaces (a token, a setting).
public final class SharedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    public init(_ value: Value? = nil) { stored = value }
    public var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
