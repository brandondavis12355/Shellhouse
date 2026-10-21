import CoreGraphics
import Foundation

/// Where a position on the VM's screen lands inside the desktop pane. noVNC scales the whole screen to fit the pane, keeping its shape,
/// so the picture is centred with bars on two sides; the bot's pointer is drawn over it at the mapped spot.
public enum PointerMapping {
    public static let screen = CGSize(width: 1280, height: 800)

    /// The part of `container` the screen picture occupies.
    public static func fit(screen: CGSize = PointerMapping.screen, into container: CGSize) -> CGRect {
        guard screen.width > 0, screen.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / screen.width, container.height / screen.height)
        let size = CGSize(width: screen.width * scale, height: screen.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The pane position of screen position (`x`, `y`), clamped to the picture.
    public static func point(x: Int, y: Int, screen: CGSize = PointerMapping.screen, in rect: CGRect) -> CGPoint {
        let fx = min(max(CGFloat(x) / screen.width, 0), 1), fy = min(max(CGFloat(y) / screen.height, 0), 1)
        return CGPoint(x: rect.minX + fx * rect.width, y: rect.minY + fy * rect.height)
    }

    /// The pointer position a tool result reports (`"pointer": {"x": …, "y": …}`), and whether the action was a click.
    public static func report(toolName: String, resultJSON: String) -> (x: Int, y: Int, clicked: Bool)? {
        guard ["click", "move_mouse"].contains(toolName),
              let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let pointer = object["pointer"] as? [String: Any],
              let x = (pointer["x"] as? Int) ?? (pointer["x"] as? Double).map(Int.init),
              let y = (pointer["y"] as? Int) ?? (pointer["y"] as? Double).map(Int.init) else { return nil }
        return (x, y, toolName == "click")
    }
}
