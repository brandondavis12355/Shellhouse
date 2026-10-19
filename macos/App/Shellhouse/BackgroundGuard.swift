import AppKit

/// Keeps the app working while its window is hidden or another app is in front.
///
/// - **App Nap off for the app's whole life.** A background app with no visible window is slowed down by macOS:
///   timers fire late, network callbacks wait. Bots' routines, group turns and the idle probe all need to run on time.
/// - **No automatic or sudden termination**, so the system never quits the app to reclaim memory while bots work.
/// - **The Mac stays awake while a bot is running** (not while everything is idle), because a sleeping Mac stops every
///   bot and drops the SSH tunnel. Turn off with `defaults write com.shellhouse.app keepAwakeWhileWorking -bool NO`.
@MainActor
final class BackgroundGuard {
    static let shared = BackgroundGuard()

    private var appLifetime: NSObjectProtocol?
    private var awake: NSObjectProtocol?
    private var releaseTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    var keepAwakeEnabled: Bool {
        UserDefaults.standard.object(forKey: "keepAwakeWhileWorking") as? Bool ?? true
    }

    /// Call once at launch. `onWake` runs a few seconds after the Mac wakes (the network needs a moment).
    func start(onWake: @escaping @MainActor () -> Void) {
        guard appLifetime == nil else { return }
        appLifetime = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Shellhouse bots run while the window is closed")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                onWake()
            }
        }
    }

    /// Called whenever a bot starts or stops working. Releases a short while after the last bot finishes, so a
    /// run of back-to-back turns doesn't take and drop the assertion each time.
    func botsWorking(_ working: Bool) {
        if working {
            releaseTask?.cancel(); releaseTask = nil
            guard awake == nil, keepAwakeEnabled else { return }
            awake = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "A Shellhouse bot is working")
        } else if awake != nil, releaseTask == nil {
            releaseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled, let self, let token = self.awake else { return }
                ProcessInfo.processInfo.endActivity(token)
                self.awake = nil; self.releaseTask = nil
            }
        }
    }
}
