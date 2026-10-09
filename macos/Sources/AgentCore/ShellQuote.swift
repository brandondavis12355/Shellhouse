/// Single-quotes `value` for a POSIX shell, so it reaches the command as one
/// literal argument whatever it contains.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
