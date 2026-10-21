import SwiftUI

/// A bug drawn like a circuit board: a hexagonal body with a trace down the middle, a square head, antennae and legs that bend at
/// 45° like PCB traces and end in solder pads. Drawn in lines so it takes the colour and weight of the other toolbar icons.
struct TechBugShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + CGFloat(x) * s, y: oy + CGFloat(y) * s) }
        var path = Path()

        // Body: a hexagon, and the spine trace through it.
        path.move(to: p(0.38, 0.40)); path.addLine(to: p(0.62, 0.40)); path.addLine(to: p(0.71, 0.60))
        path.addLine(to: p(0.62, 0.82)); path.addLine(to: p(0.38, 0.82)); path.addLine(to: p(0.29, 0.60)); path.closeSubpath()
        path.move(to: p(0.5, 0.40)); path.addLine(to: p(0.5, 0.82))
        path.move(to: p(0.5, 0.52)); path.addLine(to: p(0.60, 0.52))   // a branch off the spine

        // Head.
        path.addRect(CGRect(x: p(0.43, 0.24).x, y: p(0.43, 0.24).y, width: 0.14 * s, height: 0.10 * s))

        for side in [1.0, -1.0] {
            func q(_ x: Double, _ y: Double) -> CGPoint { p(0.5 + side * x, y) }
            // Antenna: up, then out, ending in a pad.
            path.move(to: q(0.04, 0.24)); path.addLine(to: q(0.12, 0.13)); path.addLine(to: q(0.24, 0.13))
            path.addEllipse(in: CGRect(x: q(0.24, 0.13).x - 0.022 * s, y: q(0.24, 0.13).y - 0.022 * s, width: 0.044 * s, height: 0.044 * s))
            // Three legs: out, then a 45° bend, each ending in a pad.
            // Each leg starts on the hexagon's edge, which is narrower at the top and bottom than in the middle.
            func edge(_ y: Double) -> Double { y <= 0.60 ? 0.12 + 0.09 * (y - 0.40) / 0.20 : 0.21 - 0.09 * (y - 0.60) / 0.22 }
            for (y, bend) in [(0.47, -0.07), (0.62, 0.0), (0.75, 0.07)] {
                path.move(to: q(edge(y), y)); path.addLine(to: q(0.31, y))
                if bend != 0 { path.addLine(to: q(0.38, y + bend)) }
                let end = bend != 0 ? q(0.38, y + bend) : q(0.31, y)
                path.addEllipse(in: CGRect(x: end.x - 0.022 * s, y: end.y - 0.022 * s, width: 0.044 * s, height: 0.044 * s))
            }
        }
        return path
    }
}

/// The header button that opens the Debug Console window.
struct DebugConsoleButton: View {
    @Environment(\.openWindow) private var openWindow
    var size: CGFloat = 36
    var body: some View {
        Button { openWindow(id: "debug-console") } label: {
            TechBugShape()
                .stroke(.primary, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round, lineJoin: .round))
                .padding(size * 0.2)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.glass))
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .help("Debug Console — what the bots are doing, step by step")
        .accessibilityLabel("Open the Debug Console")
    }
}
