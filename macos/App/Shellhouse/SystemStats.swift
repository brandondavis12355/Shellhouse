import AgentCore
import Foundation

/// The Linux sandbox host's address — the single source of truth for it,
/// referenced here and by `ShellhouseApp.swift`'s `SSHTunnel.Config` (see
/// that file), rather than the same host/user string living in two places
/// that could drift apart.
enum RemoteHost {
    /// Editable in Settings > Linux host (the address changes with the network).
    static var settings: HostSettings { HostSettingsStore.load() }
    static var host: String { settings.host }
    static var user: String { settings.user }
}

/// One machine's rough resource snapshot for the Settings sheet — load
/// average (not a CPU percentage: getting an accurate instantaneous CPU%
/// needs sampling over an interval on both platforms, while a load average
/// is a single cheap read everywhere and is the number `uptime`/Activity
/// Monitor's own load figure already uses) plus memory and disk.
struct MachineStats {
    var loadAverage1m: Double?
    var coreCount: Int?
    var memoryUsedGB: Double?
    var memoryTotalGB: Double?
    var diskUsedGB: Double?
    var diskTotalGB: Double?
    var error: String?
}

/// Runs a command and captures its stdout — the same `Process`-based
/// pattern already used for `SSHTunnel`/`OllamaManager`, just a one-shot
/// call instead of a supervised long-running child.
private func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 8) async -> String {
    await withCheckedContinuation { continuation in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        var resumed = false
        let lock = NSLock()
        func resume(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }

        task.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            resume(String(data: data, encoding: .utf8) ?? "")
        }

        do {
            try task.run()
        } catch {
            resume("")
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if task.isRunning { task.terminate() }
            resume("")
        }
    }
}

enum LocalMachineStats {
    /// One combined shell call rather than four separate `Process` spawns —
    /// cheaper, and the four commands' outputs are split on a marker line
    /// this app controls, so parsing can't confuse one command's output
    /// for another's.
    static func fetch() async -> MachineStats {
        let script = """
        sysctl -n vm.loadavg
        echo ---
        sysctl -n hw.ncpu
        echo ---
        sysctl -n hw.memsize
        echo ---
        vm_stat
        echo ---
        df -g /
        """
        let output = await runProcess("/bin/sh", ["-c", script])
        let sections = output.components(separatedBy: "---\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard sections.count >= 5 else { return MachineStats(error: "Could not read local stats.") }

        var stats = MachineStats()
        // "{ 1.23 1.45 1.67 }"
        if let match = sections[0].split(separator: " ").dropFirst().first, let load = Double(match) {
            stats.loadAverage1m = load
        }
        stats.coreCount = Int(sections[1])

        if let totalBytes = Double(sections[2]) {
            stats.memoryTotalGB = totalBytes / 1_073_741_824
        }

        // vm_stat: "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
        // then lines like "Pages free:                123456."
        let vmStat = sections[3]
        let pageSize = Double(firstNumber(in: vmStat, after: "page size of") ?? "4096") ?? 4096
        if let freePages = firstNumber(in: vmStat, after: "Pages free:"), let free = Double(freePages),
           let total = stats.memoryTotalGB {
            stats.memoryUsedGB = total - (free * pageSize / 1_073_741_824)
        }

        // df -g /: header line, then "/dev/diskN  <totalG>  <usedG>  <availG>  ..."
        let dfLines = sections[4].split(separator: "\n")
        if dfLines.count >= 2 {
            let fields = dfLines[1].split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3 {
                stats.diskTotalGB = Double(fields[1])
                stats.diskUsedGB = Double(fields[2])
            }
        }
        return stats
    }

    private static func firstNumber(in text: String, after marker: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}

enum RemoteMachineStats {
    /// Same one-`ssh`-call-does-everything shape as `LocalMachineStats`,
    /// over the same host/user this app already trusts for the sandbox
    /// tunnel (see `RemoteHost`) — read-only commands, no new access
    /// beyond what that connection already implies.
    static func fetch() async -> MachineStats {
        let script = """
        cat /proc/loadavg
        echo ---
        nproc
        echo ---
        free -b
        echo ---
        df -BG /
        """
        let output = await runProcess("/usr/bin/ssh", AppSSHIdentity.shared.clientOptions() + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=" + AppSSHIdentity.shared.hostKeyChecking(for: RemoteHost.host),
            "\(RemoteHost.user)@\(RemoteHost.host)",
            script,
        ])
        let sections = output.components(separatedBy: "---\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard sections.count >= 4 else {
            return MachineStats(error: "Could not reach \(RemoteHost.host) over SSH.")
        }

        var stats = MachineStats()
        // "/proc/loadavg": "0.12 0.34 0.20 1/456 12345"
        if let load = sections[0].split(separator: " ").first, let value = Double(load) {
            stats.loadAverage1m = value
        }
        stats.coreCount = Int(sections[1])

        // "free -b": header, then "Mem:  <total>  <used>  <free>  ..." in bytes
        let freeLines = sections[2].split(separator: "\n")
        if let memLine = freeLines.first(where: { $0.hasPrefix("Mem:") }) {
            let fields = memLine.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3, let total = Double(fields[1]), let used = Double(fields[2]) {
                stats.memoryTotalGB = total / 1_073_741_824
                stats.memoryUsedGB = used / 1_073_741_824
            }
        }

        // "df -BG /": header, then "/dev/sda1  50G  12G  38G  24%  /"
        let dfLines = sections[3].split(separator: "\n")
        if dfLines.count >= 2 {
            let fields = dfLines[1].split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3 {
                stats.diskTotalGB = Double(fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "G")))
                stats.diskUsedGB = Double(fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "G")))
            }
        }
        return stats
    }
}
