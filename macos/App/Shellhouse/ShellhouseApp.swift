import AppKit
import SwiftUI
import AgentCore

/// Owns the SSH tunnel to the Linux sandbox host, and the local `ollama
/// serve` process, for the app's whole lifetime: started on launch,
/// restarted automatically if either drops, torn down on quit. See
/// `SSHTunnel`/`RemoteSandboxManager` for the sandbox side and
/// `OllamaManager`/`OllamaBackend` for the model side — nothing in the app
/// talks to either directly except through these supervised processes.
///
/// Also keeps the app alive in the menu bar when the window is closed
/// (see `windowShouldClose`/`setUpStatusItem`) — every bot's background
/// work (routines firing on their own schedule, a group turn, this
/// tunnel, `ollama serve`) should keep running whether or not the
/// window happens to be open, not stop just because the red button was
/// clicked.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Lets SwiftUI views (the Ollama settings section, specifically) reach
    /// the one supervised `OllamaManager` instance instead of spawning their
    /// own — e.g. to (re)start `ollama serve` right after installing it via
    /// Homebrew, without waiting for a relaunch.
    static private(set) var shared: AppDelegate?

    let tunnel = SSHTunnel(
        config: .init(
            host: RemoteHost.host,
            user: RemoteHost.user,
            managerSocketPath: RemoteHost.settings.managerSocketPath,
            reverseForwards: SmolAgentsService.reverseForwards()
        ),
        onStderr: { line in
            // ssh's own diagnostics (auth failure, host unreachable, ...) —
            // surfaced here rather than swallowed, since a silently-dead
            // tunnel looks identical to "sandbox-manager is just slow".
            print("[ssh tunnel] \(line)")
        }
    )

    let ollama = OllamaManager(onStderr: { line in
        print("[ollama] \(line)")
    })

    private var statusItem: NSStatusItem?
    /// The `WindowGroup`'s one window — `windowShouldClose` hides it
    /// instead of letting it actually close, so `showMainWindow` can
    /// bring back this same instance rather than needing to recreate a
    /// SwiftUI scene from AppKit code (there's no simple way to do that).
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        tunnel.start()
        ollama.start()
        setUpStatusItem()
        attachToMainWindow()
    }

    /// A persistent menu-bar icon — the way back once the window's been
    /// closed (hidden) via `windowShouldClose`, since closing it no
    /// longer quits the app (see `applicationShouldTerminateAfterLastWindowClosed`).
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Shellhouse")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Shellhouse", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Shellhouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu

        statusItem = item
    }

    /// SwiftUI creates the `WindowGroup`'s window synchronously as part
    /// of launch, so it's normally already there by the time this
    /// delegate method fires — the retry is just insurance against that
    /// ordering ever changing, rather than silently ending up with no
    /// way back into the app.
    private func attachToMainWindow(attemptsLeft: Int = 5) {
        guard mainWindow == nil else { return }
        if let window = NSApp.windows.first {
            window.delegate = self
            window.backgroundColor = Theme.windowBackground
            mainWindow = window
        } else if attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.attachToMainWindow(attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        attachToMainWindow()
        (mainWindow ?? NSApp.windows.first)?.makeKeyAndOrderFront(nil)
    }

    /// The red close button hides the window instead of destroying it —
    /// see `mainWindow`'s doc comment for why that matters. `false`
    /// tells AppKit "don't actually close this," and `orderOut` is what
    /// actually removes it from the screen.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Otherwise closing the one window quits the whole app (the default
    /// for a single-`WindowGroup` app) — background work (routines on
    /// their own schedule, a live group turn, this tunnel, `ollama
    /// serve`) shouldn't stop just because the window isn't visible.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `.terminateLater` + `NSApp.reply(...)` rather than doing this in
    /// `applicationWillTerminate`: unloading models is a network call
    /// (`OllamaManager.unloadAllModels`), and that delegate method has
    /// no way to make the app actually wait for async work before
    /// exiting — it would just start the request and quit anyway.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await ollama.unloadAllModels()
            tunnel.stop()
            ollama.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ShellhouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        // The window can't be dragged smaller than its panes' minimum widths (sidebar + chat + debug).
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .windowList) { TelemetryMenuItem() }
        }

        Window("Telemetry", id: "telemetry") {
            TelemetryView()
        }
        .defaultSize(width: 1100, height: 760)
    }
}

private struct TelemetryMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Telemetry") { openWindow(id: "telemetry") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}
