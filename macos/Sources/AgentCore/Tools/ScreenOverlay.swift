import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// What the model is shown when it looks at the screen: the screenshot with a ruler along the top and left edges
/// (numbers every 100 px, ticks every 50) and a crosshair ring where the mouse pointer is. A vision model reads pixel
/// positions poorly from an unmarked picture, and a screenshot does not include the pointer, so a bot could not see where
/// a click would land until after it had landed. Only the copy sent to the model is marked: the file in the sandbox and
/// anything a person looks at stay as captured.
public enum ScreenOverlay {
    public static let rulerStep = 100

    /// `png`/JPEG bytes in, PNG bytes out at the same pixel size (so coordinates read off the picture are still screen
    /// coordinates). Returns the input unchanged if the image can't be read.
    public static func annotate(_ imageData: Data, pointer: (x: Int, y: Int)?, clicked: Bool = false) -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return imageData }
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return imageData }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Work in screen coordinates (origin top-left, y down).
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        drawRuler(ctx, width: width, height: height)
        if let pointer { drawPointer(ctx, x: pointer.x, y: pointer.y, width: width, height: height, clicked: clicked) }
        guard let marked = ctx.makeImage() else { return imageData }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return imageData }
        CGImageDestinationAddImage(destination, marked, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : imageData
    }

    private static func drawText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        ctx.fill(CGRect(x: x - 2, y: y - 1, width: bounds.width + 4, height: size + 3))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // the context is flipped: draw text upright
        ctx.textPosition = CGPoint(x: x, y: y + size - 1)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawRuler(_ ctx: CGContext, width: Int, height: Int) {
        // Each tick is drawn twice, a dark one underneath, so it shows on light and dark pages alike.
        func tick(from: CGPoint, to: CGPoint) {
            ctx.setLineWidth(3); ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.85))
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            ctx.setLineWidth(1); ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1))
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
        }
        var x = 0
        while x < width {
            let major = x % rulerStep == 0
            tick(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: major ? 10 : 6))
            if major && x > 0 { drawText(ctx, "\(x)", x: CGFloat(x) + 2, y: 9, size: 10) }
            x += rulerStep / 2
        }
        var y = 0
        while y < height {
            let major = y % rulerStep == 0
            tick(from: CGPoint(x: 0, y: y), to: CGPoint(x: major ? 10 : 6, y: y))
            if major && y > 0 { drawText(ctx, "\(y)", x: 11, y: CGFloat(y) - 6, size: 10) }
            y += rulerStep / 2
        }
    }

    /// A normal arrow cursor, its tip exactly on the pointer, so what the model sees is what a person would see; after a click, the
    /// ripple of rings a click leaves, so a click is visible in the screenshot that follows it, and a label with the position.
    private static func drawPointer(_ ctx: CGContext, x: Int, y: Int, width: Int, height: Int, clicked: Bool) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let tip = CGPoint(x: x, y: y)
        if clicked {
            for (radius, alpha) in [(10.0, 0.95), (18.0, 0.65), (27.0, 0.35)] {
                ctx.setLineWidth(2.5)
                ctx.setStrokeColor(CGColor(red: 1, green: 0.45, blue: 0.05, alpha: alpha))
                ctx.strokeEllipse(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        // The classic arrow, in points from the tip, scaled up a little so it reads in a downsized screenshot.
        let scale: CGFloat = 1.35
        let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 20), (10, 18.8), (7.2, 12.2), (12.5, 12.2)]
        func arrow() {
            ctx.move(to: CGPoint(x: tip.x + outline[0].0 * scale, y: tip.y + outline[0].1 * scale))
            for point in outline.dropFirst() { ctx.addLine(to: CGPoint(x: tip.x + point.0 * scale, y: tip.y + point.1 * scale)) }
            ctx.closePath()
        }
        arrow(); ctx.setLineWidth(4); ctx.setLineJoin(.round)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.strokePath()
        arrow(); ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fillPath()
        arrow(); ctx.setLineWidth(1); ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.strokePath()
        let label = clicked ? "clicked \(x),\(y)" : "pointer \(x),\(y)"
        drawText(ctx, label, x: min(tip.x + 18, CGFloat(width) - 120), y: min(tip.y + 26, CGFloat(height) - 16), size: 11)
    }
}
