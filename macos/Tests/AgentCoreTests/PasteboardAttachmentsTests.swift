import AppKit
import XCTest
@testable import AgentCore

final class PasteboardAttachmentsTests: XCTestCase {
    private func pasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)")) }

    private func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testAScreenshotOnThePasteboardBecomesAnImage() {
        let pb = pasteboard(); pb.clearContents()
        pb.setData(tinyPNG(), forType: .png)
        guard case .image(let data)? = PasteboardAttachments.item(from: pb) else { return XCTFail("no image") }
        XCTAssertNotNil(NSBitmapImageRep(data: data))
    }

    func testATiffImageIsConvertedToPNG() {
        let pb = pasteboard(); pb.clearContents()
        let tiff = NSBitmapImageRep(data: tinyPNG())!.representation(using: .tiff, properties: [:])!
        pb.setData(tiff, forType: .tiff)
        guard case .image(let data)? = PasteboardAttachments.item(from: pb) else { return XCTFail("no image") }
        XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "PNG signature")
    }

    func testTextIsLeftForTheFieldEvenWithAnImageAlongside() {
        let pb = pasteboard(); pb.clearContents()
        pb.setString("some words", forType: .string)
        pb.setData(tinyPNG(), forType: .png)
        XCTAssertNil(PasteboardAttachments.item(from: pb), "rich text copied with a picture still pastes as text")
        let empty = pasteboard(); empty.clearContents()
        XCTAssertNil(PasteboardAttachments.item(from: empty))
    }

    func testFilesCopiedInFinderAttachEvenThoughTheirNameIsAlsoText() {
        let pb = pasteboard(); pb.clearContents()
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        pb.writeObjects([url as NSURL])
        pb.setString("report.pdf", forType: .string)
        XCTAssertEqual(PasteboardAttachments.item(from: pb), .files([url]))
    }

    func testNotAnImageIsRefused() {
        XCTAssertNil(PasteboardAttachments.pngData(from: Data([1, 2, 3])))
    }

    func testPastedImagesAreSavedWithTimestampNamesAndOldOnesTidied() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let first = try PasteboardAttachments.save(tinyPNG(), in: dir, now: now)
        let second = try PasteboardAttachments.save(tinyPNG(), in: dir, now: now)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Pasted image ") && first.pathExtension == "png")
        XCTAssertNotEqual(first, second, "same second, different file")
        XCTAssertTrue(second.lastPathComponent.contains("(2)"))
        let old = dir.appendingPathComponent("Pasted image old.png")
        try tinyPNG().write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        _ = try PasteboardAttachments.save(tinyPNG(), in: dir, now: now.addingTimeInterval(5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "yesterday's pasted images are removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testABigScreenshotIsScaledDownAndASmallOneIsNot() throws {
        func png(_ w: Int, _ h: Int) -> Data {
            NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        }
        let big = PasteboardAttachments.limited(png(3000, 1000), maxDimension: 1600)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: big))
        XCTAssertEqual(rep.pixelsWide, 1600); XCTAssertEqual(rep.pixelsHigh, 533, accuracy: 1)
        let small = png(800, 600)
        XCTAssertEqual(PasteboardAttachments.limited(small, maxDimension: 1600), small)
    }
}
