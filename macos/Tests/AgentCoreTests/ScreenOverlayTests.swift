import CoreGraphics
import ImageIO
import XCTest
@testable import AgentCore

final class ScreenOverlayTests: XCTestCase {
    private func solidPNG(_ w: Int, _ h: Int, gray: UInt8 = 40) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(gray) / 255, green: CGFloat(gray) / 255, blue: CGFloat(gray) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// RGBA of the pixel at screen coordinates (top-left origin).
    private func pixel(_ data: Data, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let row = y   // a bitmap context stores its top row first
        let i = (row * image.width + x) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    private func size(_ data: Data) -> (Int, Int) {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        return (image.width, image.height)
    }

    func testTheImageKeepsItsSizeSoCoordinatesStayScreenCoordinates() {
        let out = ScreenOverlay.annotate(solidPNG(1280, 800), pointer: (640, 400))
        XCTAssertTrue(size(out) == (1280, 800))
    }

    func testAnArrowCursorIsDrawnWithItsTipOnThePointerAndNothingElseChanges() {
        let base = solidPNG(400, 300)
        let out = ScreenOverlay.annotate(base, pointer: (200, 150))
        let body = pixel(out, 202, 160)             // inside the arrow, a few pixels below the tip
        XCTAssertLessThan(body.r, 20); XCTAssertLessThan(body.g, 20); XCTAssertLessThan(body.b, 20, "black body")
        let edge = pixel(out, 199, 158)             // just left of the tip's stem: the white outline
        XCTAssertGreaterThan(edge.r, 200)
        XCTAssertEqual(pixel(out, 330, 270).r, pixel(base, 330, 270).r, accuracy: 3, "away from the cursor and the grid nothing changes")
        XCTAssertEqual(pixel(out, 218, 150).r, pixel(base, 218, 150).r, accuracy: 3, "no ripple unless a click happened")
    }

    func testFaintGridLinesRunEveryHundredPixelsAndStaySubtle() {
        let base = solidPNG(400, 300)
        let out = ScreenOverlay.annotate(base, pointer: nil)
        let on = pixel(out, 300, 50), off = pixel(base, 300, 50)
        XCTAssertNotEqual(on.b, off.b, "a line is drawn at x = 300")
        XCTAssertLessThan(abs(on.r - off.r), 120, "but only faintly")
        XCTAssertEqual(pixel(out, 330, 50).r, pixel(base, 330, 50).r, accuracy: 3)
    }

    func testAClickLeavesOrangeRipples() {
        let base = solidPNG(400, 300)
        let out = ScreenOverlay.annotate(base, pointer: (200, 150), clicked: true)
        let ring = pixel(out, 218, 150)             // 18 px right of the click: the second ripple
        XCTAssertGreaterThan(ring.r, 150); XCTAssertLessThan(ring.b, 120)
        XCTAssertGreaterThan(ring.r, ring.g + 40, "orange, not grey")
    }

    func testTheRulerMarksTheTopAndLeftEdgesAndNotTheMiddle() {
        let base = solidPNG(400, 300)
        let out = ScreenOverlay.annotate(base, pointer: nil)
        let tick = pixel(out, 100, 2)               // a 100 px tick at the top edge
        let b = pixel(base, 100, 2)
        XCTAssertGreaterThan(tick.r, b.r + 60); XCTAssertGreaterThan(tick.g, b.g + 50); XCTAssertLessThan(tick.b, b.b + 20, "yellow, not white")
        XCTAssertEqual(pixel(out, 250, 150).r, pixel(base, 250, 150).r, accuracy: 3)
    }

    func testAPointerOffTheScreenOrABrokenImageIsHandled() {
        let base = solidPNG(200, 100)
        XCTAssertTrue(size(ScreenOverlay.annotate(base, pointer: (5000, 5000))) == (200, 100))
        let junk = Data([1, 2, 3])
        XCTAssertEqual(ScreenOverlay.annotate(junk, pointer: (1, 1)), junk)
    }

    func testThePointerIsReadFromXdotoolsOutput() {
        let p = ToolRegistry.pointerPosition(in: "X=640\nY=400\nSCREEN=0\nWINDOW=123\n")
        XCTAssertEqual(p?.x, 640); XCTAssertEqual(p?.y, 400)
        XCTAssertNil(ToolRegistry.pointerPosition(in: ""))
        XCTAssertNil(ToolRegistry.pointerPosition(in: "X=5\n"))
    }
}
