import Foundation

/// A secret typed into a window is typed once. Typing it again goes into whatever has focus now: usually the same field,
/// which then holds two or five copies and a wrong password (and a locked account after enough tries). It is allowed
/// again after the field has been cleared or the form submitted (`ctrl+a`, Return), or after opening another page.
public final class RepeatedSecretGuard: Guard {
    public let id = "repeated_secret"
    private var typed = Set<String>()
    public init() {}

    public func reset(_ scope: GuardReset) { typed.removeAll() }

    private static func key(_ call: ToolCall) -> String? {
        guard call.name == "type_secret", let name = call.arguments["name"]?.asString else { return nil }
        return name + "|" + (call.arguments["window"]?.asString ?? "")
    }

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard let key = Self.key(call), typed.contains(key), Reliability.isOn(.loopGuards) else { return [] }
        let name = call.arguments["name"]?.asString ?? "that secret"
        return [.replaceResult(runJSONString(["error": "You already typed \(name) into this window, so the field now holds it. Typing it again "
            + "adds a second copy and makes the value wrong. Take a screenshot to see which field has it. To type it again, first select the "
            + "field's text (press_key ctrl+a) so the new text replaces it. If the field you wanted is a different one, click that field first."]),
            kind: "repeated_secret")]
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind else { return [] }
        if let key = Self.key(call), outcome.raw["ok"] as? Bool == true { typed.insert(key) }
        if call.name == "press_key", let k = call.arguments["key"]?.asString?.lowercased(),
           ["return", "kp_enter", "ctrl+a", "ctrl+backspace"].contains(k) { typed.removeAll() }
        if call.name == "open_app" { typed.removeAll() }
        return []
    }
}

/// Clicking or typing on a screen the bot has not looked at: coordinates from memory land on whatever is there (a run
/// that opened a news site by clicking where a menu used to be), and text typed with no focus goes into the page. The
/// first change of a turn (click, scroll, typing, a key, a page tool), and the first after opening an app or typing a secret,
/// must follow a screenshot: the "before". Every change result carries its own screenshot, the "after", which is the next
/// change's "before", so one look at the start is enough.
public final class LookFirstGuard: Guard {
    public let id = "look_first"
    private var looked = false
    public init() {}

    public func reset(_ scope: GuardReset) { looked = false }

    private static let needsLook: Set<String> = ["click", "move_mouse", "scroll", "type_text", "press_key", "type_secret", "click_text", "fill_field"]
    private static let showsScreen: Set<String> = ["screenshot", "click", "move_mouse", "scroll", "type_text", "click_text", "fill_field"]

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard !looked, Self.needsLook.contains(call.name), Reliability.isOn(.loopGuards) else { return [] }
        return [.replaceResult(runJSONString(["error": "You haven't looked at the screen yet this turn (or since you opened an app). Call screenshot first "
            + "and aim at what it shows: coordinates guessed or remembered from earlier often land on the wrong thing, and typed text goes "
            + "wherever the focus is. Then \(call.name) again."]), kind: "look_first")]
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind else { return [] }
        if call.name == "open_app" || call.name == "type_secret" { looked = false }
        else if call.name == "press_key" { looked = outcome.raw["screenshot"] != nil && outcome.raw["error"] == nil }
        else if Self.showsScreen.contains(call.name), outcome.raw["error"] == nil { looked = true }
        return []
    }
}

/// A username is something the bot is told, never something it makes up ("admin"). `fill_field` into a username, login or email
/// field is refused when the value appears nowhere the bot was given it: your messages, a tool result (`request_login` returns the
/// username), or memory.
public final class KnownUsernameGuard: Guard {
    public let id = "known_username"
    public init() {}

    private static let usernameish = ["user", "login", "email", "e-mail", "account", "sign in", "signin", "log in"]

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard call.name == "fill_field", Reliability.isOn(.loopGuards),
              let label = call.arguments["label"]?.asString?.lowercased(), !label.contains("password"),
              Self.usernameish.contains(where: label.contains),
              let value = call.arguments["text"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return [] }
        let needle = value.lowercased()
        let given = ctx.messages.contains { $0.role != .assistant && $0.content.lowercased().contains(needle) }
        guard !given else { return [] }
        return [.replaceResult(runJSONString(["error": "Nothing was typed: you have not been given the username \"\(value)\". Never guess one. "
            + "Use the username your user told you or request_login returned; if you have none, call request_login (it asks your user for the "
            + "username and password), or tell your user you need it."]), kind: "known_username")]
    }
}

/// A saved secret is typed into whatever has focus, so focus must have been put on the right field first: a run moved the
/// pointer over the password field, never clicked it, and typed the password into the username box. `type_secret` waits for a
/// click, `click_text`, `fill_field` or Tab since the page last changed, and for another one after each submit or new page.
public final class FocusBeforeSecretGuard: Guard {
    public let id = "focus_before_secret"
    private var focused = false
    public init() {}

    public func reset(_ scope: GuardReset) { focused = false }

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard call.name == "type_secret", !focused, Reliability.isOn(.loopGuards) else { return [] }
        return [.replaceResult(runJSONString(["error": "Nothing was typed: you have not put focus in the field yet. Click the field first "
            + "(in the browser click_text(\"Password\") or fill_field; elsewhere move_mouse onto it, then click()), check in the screenshot "
            + "that the cursor is in it, then call type_secret."]), kind: "focus_before_secret")]
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind, outcome.raw["error"] == nil else { return [] }
        switch call.name {
        case "click", "click_text", "fill_field": focused = true
        case "press_key":
            let k = call.arguments["key"]?.asString?.lowercased() ?? ""
            if k == "tab" || k == "shift+tab" { focused = true } else if ["return", "kp_enter"].contains(k) { focused = false }
        case "open_app": focused = false
        default: break
        }
        return []
    }
}

/// A click fires only on a spot the bot has seen the pointer on. `move_mouse(x, y)` puts the pointer there and returns a
/// screenshot with the arrow drawn on it; only then does `click` (with the same coordinates, or none) go through. Anything that
/// changes the screen (a click, typing, scrolling, a key, a new page) clears the aim, so each click is aimed afresh.
public final class AimFirstGuard: Guard {
    public let id = "aim_first"
    public static let tolerance = 6
    private var aimed: (x: Int, y: Int)?
    public init() {}

    public func reset(_ scope: GuardReset) { aimed = nil }

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard call.name == "click", Reliability.isOn(.loopGuards) else { return [] }
        let x = call.arguments["x"]?.asInt, y = call.arguments["y"]?.asInt
        if let a = aimed {
            if x == nil || y == nil || (abs(a.x - x!) <= Self.tolerance && abs(a.y - y!) <= Self.tolerance) { return [] }
        }
        let why = aimed == nil
            ? "You have not moved the pointer onto the target yet."
            : "The pointer is at (\(aimed!.x), \(aimed!.y)), not where you asked to click."
        return [.replaceResult(runJSONString(["error": "\(why) Nothing was clicked. Call move_mouse(x, y) on the target, check in the screenshot "
            + "that the arrow's tip is on it, then call click() with no coordinates. (In the browser, click_text needs no aiming.)"]), kind: "aim_first")]
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind else { return [] }
        switch call.name {
        case "move_mouse":
            if outcome.raw["error"] == nil, let x = call.arguments["x"]?.asInt, let y = call.arguments["y"]?.asInt { aimed = (x, y) } else { aimed = nil }
        case "screenshot", "find_on_page", "page_text", "list_windows":
            break
        case "click", "type_text", "type_secret", "scroll", "press_key", "open_app", "click_text", "fill_field":
            aimed = nil
        default:
            break
        }
        return []
    }
}

/// Clicking the same spot again and again (a pixel apart, so an exact-repeat check never fires) while the screen does not
/// change. After three the bot is told to look at the screenshot and aim elsewhere or move focus with the keyboard.
public final class NearRepeatClickGuard: Guard {
    public let id = "near_repeat_click"
    public static let radius = 8
    private var last: (x: Int, y: Int)?
    private var streak = 0
    public init() {}

    public func reset(_ scope: GuardReset) { last = nil; streak = 0 }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind else { return [] }
        guard call.name == "click", let x = call.arguments["x"]?.asInt, let y = call.arguments["y"]?.asInt else {
            // Typing, a key or a new page is progress; a screenshot is only looking.
            if call.name != "screenshot" { last = nil; streak = 0 }
            return []
        }
        if let l = last, abs(l.x - x) <= Self.radius, abs(l.y - y) <= Self.radius { streak += 1 } else { streak = 1 }
        last = (x, y)
        guard Reliability.isOn(.loopGuards), streak == 3 || streak == 6 else { return [] }
        let tail = streak == 6 ? " You have clicked here six times; stop clicking this spot." : ""
        return [.nudge(Nudge(kind: "near_repeat_click", text:
            "You have clicked within a few pixels of (\(x), \(y)) \(streak) times and the screen is not changing as you expect.\(tail) "
            + "Look at the latest screenshot and work out where the element you want really is (the field above or below may be a "
            + "different y), click there, or move focus with the keyboard (press_key Tab or shift+Tab) instead.", escalation: .specific))]
    }
}
