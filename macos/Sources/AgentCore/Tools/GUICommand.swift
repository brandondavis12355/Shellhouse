import CoreGraphics
import Foundation

/// The desktop tools (screenshot, click, type, press_key, scroll, windows, open_app) talk to the VM's X display.
/// A command run over ssh does not inherit the desktop session's `DISPLAY`, so every one of them said
/// "Can't open display" and the bot went round in circles. They now set it, and a missing desktop is reported once,
/// in words, instead of as a Python traceback or a `Missing X server` line.
public enum GUICommand {
    public static let display = ":1"

    public static func wrap(_ command: String) -> String { "export DISPLAY=\"${DISPLAY:-\(display)}\"; " + command }

    /// Exit codes of `openApp`'s script.
    static let noDisplayExit = 4, didNotStartExit = 5, alreadyOpenExit = 7

    /// Opens an app and checks that it actually started: the old command backgrounded it and reported success whatever happened.
    /// `once`: what is being opened (a URL). The same thing asked for again within three minutes, while the app is still
    /// running, is not opened again: every repeat of `chromium URL` is another tab, and a bot that is unsure it worked
    /// asks again and again.
    /// `controllable`: for the browser, a command that is true when it can be remote-controlled. A browser that is already running without that
    /// (started some other way) is closed first and started again with it, since the page tools can't reach it otherwise.
    public static func openApp(process: String, launch: String, once: String? = nil, controllable: String? = nil) -> String {
        var script = "xdotool getdisplaygeometry >/dev/null 2>&1 || exit \(noDisplayExit); "
        if let controllable {
            script += "if pgrep -x \(process) >/dev/null && ! \(controllable); then pkill -x \(process); sleep 1.5; fi; "
        }
        if let once, !once.isEmpty {
            let marker = shellQuote("/tmp/.shellhouse-opened-\(process)")
            script += "if pgrep -x \(process) >/dev/null && [ \"$(cat \(marker) 2>/dev/null)\" = \(shellQuote(once)) ] "
                + "&& [ -n \"$(find \(marker) -mmin -3 2>/dev/null)\" ]; then exit \(alreadyOpenExit); fi; "
                + "printf %s \(shellQuote(once)) > \(marker); "
        }
        script += "nohup \(launch) >/dev/null 2>&1 & disown; "
            + "for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; pgrep -x \(process) >/dev/null && exit 0; done; exit \(didNotStartExit)"
        return wrap(script)
    }

    /// A click that behaves like a hand: the pointer travels along a curve with easing and a little wobble, settles on the
    /// target for a moment (pages react to hover before a press), presses, holds for 60 to 110 ms, releases, and the script
    /// reports where the pointer really ended and which window is under it. `xdotool click` pressed and released in the same
    /// instant, which some pages ignore. Python is in the VM already; the script travels with the app, so existing VMs get it.
    public static func click(x: Int, y: Int, button: Int) -> String {
        wrap("python3 - \(x) \(y) \(button) <<'PY'\n\(clickScript)\nPY")
    }

    public static let clickScript = """
    import json, math, random, subprocess, sys
    tx, ty, button = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    def xd(*a):
        return subprocess.run(["xdotool", *a], capture_output=True, text=True, check=True).stdout
    def where():
        v = dict(l.split("=", 1) for l in xd("getmouselocation", "--shell").split() if "=" in l)
        return int(v["X"]), int(v["Y"]), v.get("WINDOW", "")
    sx, sy, _ = where()
    dist = math.hypot(tx - sx, ty - sy)
    steps = max(5, min(12, int(dist / 40) + 5))
    side = random.choice((-1, 1)) * min(60, dist * 0.12)
    nx, ny = (-(ty - sy) / (dist or 1), (tx - sx) / (dist or 1))
    cx, cy = (sx + tx) / 2 + nx * side, (sy + ty) / 2 + ny * side
    # The whole gesture is ONE xdotool command (it chains `mousemove`, `sleep`, `mousedown` ...): starting a process per step took
    # about half a second each in the VM, so one click took sixteen.
    chain = []
    for i in range(1, steps):
        t = i / steps
        e = t * t * (3 - 2 * t)
        x = (1 - e) ** 2 * sx + 2 * (1 - e) * e * cx + e * e * tx + random.uniform(-1.2, 1.2)
        y = (1 - e) ** 2 * sy + 2 * (1 - e) * e * cy + e * e * ty + random.uniform(-1.2, 1.2)
        chain += ["mousemove", str(round(x)), str(round(y)), "sleep", "0.012"]
    chain += ["mousemove", "--sync", str(tx), str(ty), "sleep", "0.12",
              "mousemove", "--sync", str(tx + 1), str(ty), "mousemove", "--sync", str(tx), str(ty), "sleep", "0.05",
              "mousedown", button, "sleep", "%.3f" % random.uniform(0.06, 0.11), "mouseup", button]
    xd(*chain)
    x, y, win = where()
    name = ""
    if win:
        try: name = xd("getwindowname", win).strip()
        except Exception: pass
    print(json.dumps({"pointer": {"x": x, "y": y}, "landed": abs(x - tx) <= 2 and abs(y - ty) <= 2, "window": name}))
    """

    /// What to tell the bot about how the screen reacted to its action: a plain yes, or, when nothing moved, what that usually means.
    public static func reaction(_ changed: Double?, after action: String, region: CGRect? = nil) -> [String: Any] {
        guard let changed else { return [:] }
        if changed >= ScreenDiff.reactionThreshold {
            var out: [String: Any] = ["screen_changed": true]
            if let region {
                out["changed_region"] = ["x": Int(region.minX), "y": Int(region.minY), "w": Int(region.width), "h": Int(region.height)]
                out["compare"] = "Compared with the screen before this action, the area that changed is the box in changed_region. Check it is "
                    + "the change you expected (a field filled, a page or menu opened); if it is elsewhere, the action hit the wrong thing."
            }
            return out
        }
        let note: String
        switch action {
        case "click":
            note = "Nothing on the screen changed after this click: it probably landed on something that isn't clickable, or the page ignored it. "
                + "Compare the orange ripple with the target in the screenshot. Try another spot on the target, or reach it with the keyboard "
                + "(press_key Tab until it is focused, then Return). Don't repeat the same click."
        case "type_text":
            note = "Nothing on the screen changed after typing: the text probably went nowhere because no field has focus. Click the field first."
        default:
            note = "The screen did not change: the page may already be at its end, or nothing there scrolls."
        }
        return ["screen_changed": false, "note": note]
    }

    public static let alreadyOpenNote = "That page is already open in the browser (opened a moment ago); opening it again would only add another tab. "
        + "Take a screenshot to see it. To go to a different page, call open_app again with that page's url."

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
