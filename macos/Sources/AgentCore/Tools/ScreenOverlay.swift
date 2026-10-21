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
    public static func annotate(_ imageData: Data, pointer: (x: Int, y: Int)?) -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return imageData }
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return imageData }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Work in screen coordinates (origin top-left, y down).
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
        drawRuler(ctx, width: width, height: height)
        if let pointer { drawPointer(ctx, x: pointer.x, y: pointer.y, width: width, height: height) }
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

    /// A ring with a gap in the middle, so the pixel under the pointer stays visible, and its position in words.
    private static func drawPointer(_ ctx: CGContext, x: Int, y: Int, width: Int, height: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let c = CGPoint(x: x, y: y), r: CGFloat = 16, gap: CGFloat = 4
        func stroke(_ color: CGColor, _ lineWidth: CGFloat) {
            ctx.setStrokeColor(color); ctx.setLineWidth(lineWidth)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                ctx.move(to: CGPoint(x: c.x + dx * gap, y: c.y + dy * gap))
                ctx.addLine(to: CGPoint(x: c.x + dx * (r + 6), y: c.y + dy * (r + 6)))
            }
            ctx.strokePath()
        }
        stroke(CGColor(red: 1, green: 1, blue: 1, alpha: 1), 5)
        stroke(CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1), 2.5)
        let label = "pointer \(x),\(y)"
        drawText(ctx, label, x: min(c.x + r + 8, CGFloat(width) - 110), y: max(c.y - r - 16, 14), size: 11)
    }
}
