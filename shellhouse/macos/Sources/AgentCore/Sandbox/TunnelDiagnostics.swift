import Foundation

/// Turns the raw `ssh` complaints the tunnel prints into something actionable, and stops the same one from
/// scrolling past every 20 seconds.
public struct TunnelDiagnostics: Sendable {
    private var lastShown: [String: Date] = [:]
    public let repeatEvery: TimeInterval

    public init(repeatEvery: TimeInterval = 120) { self.repeatEvery = repeatEvery }

    /// A plain-English explanation for a known failure, nil for lines we have nothing to add to.
    public static func explain(_ line: String) -> (key: String, text: String)? {
        let lower = line.lowercased()
        if lower.contains("remote port forwarding failed for listen port"), let port = line.components(separatedBy: "listen port ").last?.split(separator: " ").first {
            return ("remote-forward-\(port)",
                "The host would not open port \(port) for the model proxy. Most often an older tunnel session still holds it (the host frees it "
                + "once it notices the session is dead, within a couple of minutes with the keepalive rule from scripts/enable-model-proxy-forward.sh; "
                + "or end the old `sshd: <user>` session on the host). The other cause is the host's sshd rule (GatewayPorts clientspecified + PermitListen "
                + "for the Docker bridge address) being missing or different: re-run that script on the host. Retrying automatically.")
        }
        if lower.contains("permission denied (publickey") || lower.hasSuffix("permission denied") {
            return ("auth", "The host did not accept the app's SSH key. Open Settings › Linux host, click \"Copy authorize command\", paste it into Terminal, then press Test.")
        }
        if lower.contains("operation not permitted") && (lower.contains(".ssh") || lower.contains("load key")) {
            return ("sandbox-ssh", "The app's sandbox blocked a file under ~/.ssh. The app should use its own key (Settings › Linux host); this build may be old.")
        }
        if lower.contains("could not resolve hostname") || lower.contains("no route to host") || lower.contains("connection timed out") || lower.contains("network is unreachable") {
            return ("unreachable", "Can't reach the Linux host. Check you're on the same network or VPN, or use \"Find on this network\" in Settings › Linux host.")
        }
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            return ("hostkey", "The host's SSH identity changed. If you did not reinstall it, don't proceed; if you did, remove its line from the app's known_hosts and reconnect.")
        }
        return nil
    }

    /// What to print for `line` now: the raw line plus the explanation the first time, then nothing until `repeatEvery`
    /// has passed (and a short count of what was skipped). Unknown lines pass through unchanged.
    public mutating func lineToShow(_ line: String, now: Date = Date()) -> String? {
        guard let known = Self.explain(line) else { return line }
        if let last = lastShown[known.key], now.timeIntervalSince(last) < repeatEvery { return nil }
        lastShown[known.key] = now
        return "\(line)\n  → \(known.text)"
    }
}
