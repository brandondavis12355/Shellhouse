import AppKit
import SwiftUI

/// Design tokens for the app's look: near-black canvas, slightly lighter
/// rounded "cards" for grouped content, soft gray chat bubbles, translucent
/// circular icon buttons and a white primary action — modeled on the
/// reference mobile screenshots. Every token is appearance-adaptive (a light
/// variant exists for "Light"/"System" in Settings), but the dark values are
/// the design target and the default (see `ContentView.appearanceMode`).
enum Theme {
    // MARK: Surfaces

    /// The window/canvas behind everything.
    static let bg = adaptive(NSColor(rgb: 0xF2F2F7), NSColor(rgb: 0x0C0C0E))
    /// Grouped-content cards, the composer pill, popovers.
    static let card = adaptive(.white, NSColor(rgb: 0x1C1C1E))
    /// Assistant / other-speaker chat bubble.
    static let bubble = adaptive(NSColor(rgb: 0xE6E6EB), NSColor(rgb: 0x242427))
    /// Your own chat bubble — a step lighter than `bubble` so the two read apart.
    static let userBubble = adaptive(NSColor(rgb: 0xCFE2FF), NSColor(rgb: 0x3A3A3E))
    /// Role pills, text-field fills inside a card, secondary buttons.
    static let chip = adaptive(NSColor(rgb: 0xE5E5EA), NSColor(rgb: 0x2C2C2F))

    // MARK: Overlays

    /// Translucent fill behind circular icon buttons and the header pill.
    static let glass = adaptive(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.10))
    /// 1pt separators and outlines.
    static let hairline = adaptive(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.09))
    /// Selected / hovered sidebar row.
    static let selection = adaptive(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.08))

    // MARK: Accents

    static let accent = adaptive(NSColor(rgb: 0x007AFF), NSColor(rgb: 0x0A84FF))
    /// Toggles and "ok" states.
    static let positive = adaptive(NSColor(rgb: 0x34C759), NSColor(rgb: 0x30D158))
    /// Sign-out-style red: destructive rows and buttons.
    static let destructive = adaptive(NSColor(rgb: 0xFF3B30), NSColor(rgb: 0xFF6B66))
    static let warning = adaptive(NSColor(rgb: 0xFF9500), NSColor(rgb: 0xFF9F0A))
    /// The white (dark mode) / black (light mode) primary action fill, and the
    /// glyph color on top of it.
    static let primaryFill = adaptive(NSColor(rgb: 0x111113), .white)
    static let onPrimary = adaptive(.white, NSColor(rgb: 0x0C0C0E))

    // MARK: Shape

    static let cardRadius: CGFloat = 20
    static let bubbleRadius: CGFloat = 22
    static let fieldRadius: CGFloat = 12
    static let composerRadius: CGFloat = 26

    /// Widest the message column gets — keeps lines readable in a big window.
    static let chatColumnWidth: CGFloat = 820

    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// The window background as an `NSColor`, for AppKit-level use.
    static var windowBackground: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(rgb: 0x0C0C0E) : NSColor(rgb: 0xF2F2F7)
        }
    }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Timestamps

enum Stamp {
    /// Messages-style: time today, weekday this week, short date otherwise.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
