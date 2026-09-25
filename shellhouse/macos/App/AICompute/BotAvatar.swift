import SwiftUI
import WebKit

/// 8 fixed "mascot" shapes a bot's avatar can be — same color-blob language
/// as the original single style, just varied silhouettes so bots are
/// distinguishable at a glance even before reading the name. Purely cosmetic,
/// picked per-bot in the settings sheet (`avatarStyle`, an index into
/// `AvatarStyle.allCases`).
///
/// Each case name doubles as the shape-half of the bundled SVG filenames in
/// `avatars/` (`blob_purple.svg`, `diamond_cyan.svg`, …) — see
/// `AnimatedAvatarView.assetName`.
enum AvatarStyle: Int, CaseIterable, Identifiable {
    case blob, diamond, circle, hexagon, capsule, star, cloud, pixel

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .blob: return "Blob"
        case .diamond: return "Diamond"
        case .circle: return "Circle"
        case .hexagon: return "Hexagon"
        case .capsule: return "Capsule"
        case .star: return "Star"
        case .cloud: return "Cloud"
        case .pixel: return "Pixel"
        }
    }

    var assetShapeName: String {
        switch self {
        case .blob: return "blob"
        case .diamond: return "diamond"
        case .circle: return "circle"
        case .hexagon: return "hexagon"
        case .capsule: return "capsule"
        case .star: return "star"
        case .cloud: return "cloud"
        case .pixel: return "pixel"
        }
    }
}

/// A bot's avatar — one of 64 bundled, pre-animated SVGs (8 shapes x 8
/// colors, in `avatars/`; see `project.yml`'s folder resource entry), each
/// with its own hand-tuned CSS animation (a bounce, a spin, a wiggle, a
/// twinkle, …) baked in by whoever designed them.
///
/// Rendered through a small transparent `WKWebView` (`AnimatedAvatarView`)
/// rather than natively: AppKit/SwiftUI have no renderer for an SVG's
/// embedded `<style>` `@keyframes` — `Image`/`NSImage` only ever draw an
/// SVG's first static frame — and WebKit is the one thing on this platform
/// that plays CSS animations, the same reason `ComputerPanel` already
/// embeds a `WKWebView` for noVNC rather than a native VNC client.
struct BotAvatar: View {
    let colorHex: String
    var style: AvatarStyle = .blob
    var size: CGFloat = 28

    var body: some View {
        AnimatedAvatarView(style: style, colorHex: colorHex)
            .frame(width: size, height: size)
    }
}

/// Loads one bundled avatar SVG (picked by shape + nearest asset color to
/// `colorHex`) into an inline HTML wrapper that forces it to fill the view
/// and keeps the background transparent, then plays it in a `WKWebView`.
private struct AnimatedAvatarView: NSViewRepresentable {
    let style: AvatarStyle
    let colorHex: String

    /// The 8 colors the bundled SVGs actually ship in — matched against
    /// `colorHex` by nearest RGB distance rather than exact string equality,
    /// so a bot on a custom `ColorPicker` color (not one of
    /// `botColorPalette`'s swatches) still gets a real asset instead of
    /// silently falling back to nothing.
    private static let assetColors: [(name: String, hex: String)] = [
        ("purple", "#7C3AED"), ("cyan", "#16B8E6"), ("green", "#22C55E"), ("orange", "#F97316"),
        ("red", "#EF4444"), ("yellow", "#EAB308"), ("pink", "#EC4899"), ("teal", "#14B8A6"),
    ]

    private var assetName: String {
        "\(style.assetShapeName)_\(Self.nearestAssetColorName(to: colorHex)).svg"
    }

    private static func nearestAssetColorName(to hex: String) -> String {
        let target = rgb(hex)
        return assetColors.min(by: { distance(rgb($0.hex), target) < distance(rgb($1.hex), target) })?.name ?? "purple"
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        return (Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
    }

    private static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)
    }

    /// Remembers which asset is currently loaded so `updateNSView` — called
    /// on every SwiftUI re-render of the containing view, not just when
    /// `style`/`colorHex` actually change — doesn't reload (and restart the
    /// CSS animation from frame zero, a visible stutter) on unrelated
    /// updates.
    final class Coordinator {
        var loadedAssetName: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        // `underPageBackgroundColor` (tried as a replacement for the
        // private `drawsBackground` KVC key — see `ComputerView`) only
        // colors what's under the PAGE's own content; it doesn't make
        // this view's own backing layer non-opaque the way `drawsBackground`
        // did, which is what these animated SVGs actually need to blend
        // into the app's own background instead of showing an opaque box.
        // Reverted here — this crash turned out unrelated to this call.
        webView.setValue(false, forKey: "drawsBackground")
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
    }

    /// The SVG's own `viewBox` (no explicit `width`/`height`) would
    /// otherwise render at a browser's default intrinsic size rather than
    /// filling this view — this wraps it in a minimal document that forces
    /// full-bleed sizing and a transparent page instead.
    private func load(into webView: WKWebView, coordinator: Coordinator) {
        let name = assetName
        guard coordinator.loadedAssetName != name else { return }
        coordinator.loadedAssetName = name
        let baseName = name.replacingOccurrences(of: ".svg", with: "")
        guard let url = Bundle.main.url(forResource: baseName, withExtension: "svg", subdirectory: "avatars")
            ?? Bundle.main.url(forResource: baseName, withExtension: "svg"),
            let svg = try? String(contentsOf: url, encoding: .utf8) else { return }
        let html = """
        <html><head><style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        svg{width:100%;height:100%;display:block}
        </style></head><body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

/// The 8-shape picker grid shown in the bot settings sheet.
struct AvatarPicker: View {
    let colorHex: String
    @Binding var selection: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(AvatarStyle.allCases) { style in
                Button {
                    selection = style.rawValue
                } label: {
                    VStack(spacing: 4) {
                        BotAvatar(colorHex: colorHex, style: style, size: 54)
                        Text(style.label).font(.caption2)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(selection == style.rawValue ? Color.accentColor.opacity(0.18) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == style.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
