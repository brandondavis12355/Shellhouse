import CoreGraphics
import ImageIO
import XCTest
@testable import AgentCore

final class ScreenDiffTests: XCTestCase {
    private func png(_ w: Int = 640, _ h: Int = 400, box: CGRect? = nil, gray: CGFloat = 0.9) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let box { ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.4, alpha: 1)); ctx.fill(box) }
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
        return out as Data
    }

    func testTheSameScreenIsUnchanged() {
        XCTAssertEqual(ScreenDiff.changedFraction(png(), png()) ?? 1, 0, accuracy: 0.0001)
    }

    func testAPageChangeIsSeenAndATinyBlinkIsNot() throws {
        let page = try XCTUnwrap(ScreenDiff.changedFraction(png(), png(box: CGRect(x: 100, y: 100, width: 300, height: 200))))
        XCTAssertGreaterThan(page, ScreenDiff.reactionThreshold * 10)
        let blink = try XCTUnwrap(ScreenDiff.changedFraction(png(), png(box: CGRect(x: 300, y: 200, width: 2, height: 14))))
        XCTAssertLessThan(blink, ScreenDiff.reactionThreshold, "a text cursor blinking is not the page reacting")
    }

    func testUnreadableImagesGiveNoAnswer() {
        XCTAssertNil(ScreenDiff.changedFraction(Data([1, 2]), png()))
    }

    func testTheNoteSaysWhatANonReactionUsuallyMeans() {
        XCTAssertEqual(GUICommand.reaction(0.3, after: "click")["screen_changed"] as? Bool, true)
        XCTAssertNil(GUICommand.reaction(0.3, after: "click")["note"])
        let dead = GUICommand.reaction(0.0, after: "click")
        XCTAssertEqual(dead["screen_changed"] as? Bool, false)
        XCTAssertTrue((dead["note"] as? String)?.contains("Don't repeat the same click") == true)
        XCTAssertTrue((GUICommand.reaction(0, after: "type_text")["note"] as? String)?.contains("focus") == true)
        XCTAssertTrue(GUICommand.reaction(nil, after: "click").isEmpty, "the first screenshot has nothing to compare with")
    }

    func testTheMemoryComparesWithTheLastCaptureOfThatSandbox() {
        let memory = ScreenMemory()
        XCTAssertNil(memory.record(png(), for: "a"))
        XCTAssertEqual(memory.record(png(), for: "a") ?? 1, 0, accuracy: 0.0001)
        XCTAssertNil(memory.record(png(box: CGRect(x: 0, y: 0, width: 400, height: 300)), for: "b"), "another sandbox has its own history")
        XCTAssertGreaterThan(memory.record(png(box: CGRect(x: 0, y: 0, width: 400, height: 300)), for: "a") ?? 0, 0.1)
    }
}
