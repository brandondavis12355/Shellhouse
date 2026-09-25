import Foundation
import AgentCore

// Headless driver: exercises the runtime and runs eval suites before any UI
// exists. Keeping a CLI path means the Swift port can be scored against the
// same evals/suites/*.json as the Python build, so "is the port as good?" has
// a numeric answer.
//
// Intended commands:
//   aic doctor                 check host support, Ollama, guest image
//   aic vm up|down|shell       drive a sandbox directly
//   aic task "goal"            run one task to completion
//   aic eval suites/files.json run a suite and print a score

@main
struct AgentCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print("""
            usage: aic <command>

              doctor    verify this Mac can run agent sandboxes
              vm        sandbox lifecycle (not implemented)
              task      run one task (not implemented)
              eval      run an eval suite (not implemented)
            """)
            return
        }

        switch command {
        case "doctor":
            await doctor()
        default:
            print("'\(command)' is not implemented yet. See macos/README.md.")
        }
    }

    /// The first thing worth building: tell the user why nothing works.
    static func doctor() async {
        print("Checking host support…")

        #if canImport(Virtualization)
        do {
            try await VirtualizationSandbox.checkHostSupport()
            print("  [ok]   Virtualization.framework available")
        } catch {
            print("  [FAIL] \(error.localizedDescription)")
        }
        #else
        print("  [FAIL] Virtualization.framework not available on this platform")
        #endif

        // Model server
        do {
            let models = try await OllamaBackend().availableModels()
            if models.isEmpty {
                print("  [warn] Ollama is running but has no models pulled.")
                print("         ollama pull qwen2.5:7b-instruct")
            } else {
                print("  [ok]   Ollama: \(models.count) model(s)")
                for model in models.prefix(5) { print("           \(model)") }
            }
        } catch {
            print("  [FAIL] Ollama unreachable — start it with `ollama serve`")
        }
    }
}
