import Foundation
import AgentCore

/// Wires Settings > Skills' "Install from npx skills@latest" field to the
/// real `skills` CLI (npm package `skills`, https://github.com/vercel-labs/skills
/// — verified live before writing this: `npm view skills`, and a real
/// `npx skills@latest add <pkg> --skill <name> --copy -y --json` run in an
/// isolated scratch directory).
///
/// That CLI is built to install into a coding *agent's* own skills folder
/// (for example `.claude/skills`) — it auto-detects whichever
/// agents it finds configured on the machine and copies into all of them.
/// This app isn't one of the agents it knows about, so instead of fighting
/// its auto-detection, every install runs in a throwaway scratch directory
/// and reads back `.agents/skills/<name>/SKILL.md` — the one location it
/// writes unconditionally regardless of which specific agents it happened
/// to detect — then imports each into this app's own library via
/// `SkillLibrary.saveUserSkill`.
enum SkillInstaller {
    enum InstallError: LocalizedError {
        case npxNotFound
        case commandFailed(String)
        case nothingImported(String)

        var errorDescription: String? {
            switch self {
            case .npxNotFound:
                return "npx not found — install Node.js (nodejs.org) first."
            case .commandFailed(let detail):
                return detail
            case .nothingImported(let detail):
                return "Ran, but nothing was imported. \(detail)"
            }
        }
    }

    private static var scratchDirectory: URL {
        let dir = AppData.url("skills-installer")
        // A clean slate every run — this directory only ever exists for the
        // lifetime of one install, never something to accumulate state in.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `package` is anything the CLI itself accepts (`vercel-labs/agent-skills`,
    /// a bare registry name like `notion`, a GitHub URL, …). `skill`, if
    /// non-empty, limits the install to that one skill name within the
    /// package; empty installs everything the package offers.
    static func install(package: String, skill: String) async -> Result<[String], InstallError> {
        let trimmedPackage = package.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPackage.isEmpty else { return .failure(.commandFailed("Enter a package to install.")) }
        let skillArg = skill.trimmingCharacters(in: .whitespaces).isEmpty ? "*" : skill

        let dir = scratchDirectory
        defer { try? FileManager.default.removeItem(at: dir) }

        // A login shell (`-l`), not a bare `/usr/bin/env npx`: GUI apps
        // don't inherit Terminal's PATH, and npx commonly lives somewhere
        // only a login shell's profile (nvm, volta, Homebrew on Apple
        // Silicon, …) actually puts on PATH.
        let command = "npx --yes skills@latest add \(shellQuote(trimmedPackage)) --skill \(shellQuote(skillArg)) "
            + "--copy -y --json"
        let (exitCode, output) = await run(command, currentDirectory: dir, timeout: 120)

        if output.contains("command not found") || output.contains("npx: not found") {
            return .failure(.npxNotFound)
        }

        let agentsSkillsDir = dir.appendingPathComponent(".agents/skills")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: agentsSkillsDir, includingPropertiesForKeys: nil
        ) else {
            return .failure(exitCode == 0 ? .nothingImported("") : .commandFailed(lastMeaningfulLine(output)))
        }

        var imported: [String] = []
        for entry in entries {
            guard let content = try? String(contentsOf: entry.appendingPathComponent("SKILL.md"), encoding: .utf8) else {
                continue
            }
            let name = entry.lastPathComponent
            if (try? SkillLibrary.saveUserSkill(id: SkillLibrary.slugify(name), content: content)) != nil {
                imported.append(name)
            }
        }

        guard !imported.isEmpty else { return .failure(.nothingImported(lastMeaningfulLine(output))) }
        return .success(imported)
    }

    /// The CLI's progress output is mostly spinner-frame noise (see the
    /// raw output captured while verifying this against the real tool) —
    /// this is a rough best-effort pull of the last non-empty, non-spinner
    /// line for a one-line error message, not a real parser for it.
    private static func lastMeaningfulLine(_ output: String) -> String {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "│" }
        return lines.last ?? "No output."
    }

    private static func run(_ command: String, currentDirectory: URL, timeout: TimeInterval) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-l", "-c", command]
            task.currentDirectoryURL = currentDirectory
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            let lock = NSLock()
            var resumed = false
            func resume(_ code: Int32, _ text: String) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: (code, text))
            }

            task.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                resume(process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            }

            do {
                try task.run()
            } catch {
                resume(-1, error.localizedDescription)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if task.isRunning { task.terminate() }
                resume(-1, "Timed out after \(Int(timeout))s")
            }
        }
    }
}
