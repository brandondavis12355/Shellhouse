import Foundation

/// The desktop tools (screenshot, click, type, press_key, scroll, windows, open_app) talk to the VM's X display.
/// A command run over ssh does not inherit the desktop session's `DISPLAY`, so every one of them said
/// "Can't open display" and the bot went round in circles. They now set it, and a missing desktop is reported once,
/// in words, instead of as a Python traceback or a `Missing X server` line.
public enum GUICommand {
    public static let display = ":1"

    public static func wrap(_ command: String) -> String { "export DISPLAY=\"${DISPLAY:-\(display)}\"; " + command }

    /// Exit codes of `openApp`'s script.
    static let noDisplayExit = 4, didNotStartExit = 5

    /// Opens an app and checks that it actually started: the old command backgrounded it and reported success whatever happened.
    public static func openApp(process: String, launch: String) -> String {
        wrap("xdotool getdisplaygeometry >/dev/null 2>&1 || exit \(noDisplayExit); nohup \(launch) >/dev/null 2>&1 & disown; "
            + "for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; pgrep -x \(process) >/dev/null && exit 0; done; exit \(didNotStartExit)")
    }

    public static let noDesktopMessage = "This VM has no running desktop (nothing is answering on the X display \(display)), so graphical apps, "
        + "screenshots, clicks and typing cannot work. That is a VM problem, not something to retry: tell the user, and for anything that "
        + "does not need to be seen, use run_shell, fetch_url or the command line instead."

    /// A tool's stderr as the bot should read it: the desktop problem in one sentence, a traceback as its last line.
    public static func failure(_ stderr: String, exitCode: Int32 = 1, app: String? = nil) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if (exitCode == Int32(noDisplayExit) && app != nil) || lower.contains("can't open display") || lower.contains("cannot open display")
            || lower.contains("missing x server") || lower.contains("failed creating new xdo instance")
            || (lower.contains("xdotool") && lower.contains("getmouselocation") && lower.contains("traceback")) {
            return noDesktopMessage
        }
        if exitCode == Int32(didNotStartExit), let app { return "\(app) did not start within 5 seconds. Take a screenshot to see what is on screen before trying again." }
        if text.contains("Traceback"), let last = text.split(separator: "\n").last { return String(last) }
        return text.isEmpty ? "failed (exit \(exitCode))" : text
    }
}
