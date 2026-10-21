import XCTest
@testable import AgentCore

final class PointerMappingTests: XCTestCase {
    func testTheScreenIsCentredAndKeepsItsShape() {
        let wide = PointerMapping.fit(into: CGSize(width: 1600, height: 800))     // pane wider than the 8:5 screen: bars left and right
        XCTAssertEqual(wide.height, 800, accuracy: 0.01); XCTAssertEqual(wide.width, 1280, accuracy: 0.01); XCTAssertEqual(wide.minX, 160, accuracy: 0.01)
        let tall = PointerMapping.fit(into: CGSize(width: 640, height: 640))      // pane taller: bars top and bottom
        XCTAssertEqual(tall.width, 640, accuracy: 0.01); XCTAssertEqual(tall.height, 400, accuracy: 0.01); XCTAssertEqual(tall.minY, 120, accuracy: 0.01)
        XCTAssertEqual(PointerMapping.fit(into: .zero), .zero)
    }

    func testAScreenPositionMapsIntoThePicture() {
        let rect = PointerMapping.fit(into: CGSize(width: 640, height: 640))
        let centre = PointerMapping.point(x: 640, y: 400, in: rect)
        XCTAssertEqual(centre.x, 320, accuracy: 0.01); XCTAssertEqual(centre.y, 320, accuracy: 0.01)
        let corner = PointerMapping.point(x: 0, y: 0, in: rect)
        XCTAssertEqual(corner.x, 0, accuracy: 0.01); XCTAssertEqual(corner.y, 120, accuracy: 0.01)
        let outside = PointerMapping.point(x: 5000, y: -10, in: rect)
        XCTAssertEqual(outside.x, 640, accuracy: 0.01); XCTAssertEqual(outside.y, 120, accuracy: 0.01, "clamped to the picture")
    }

    func testOnlyAClickOrAMoveWithAPointerCounts() {
        let click = PointerMapping.report(toolName: "click", resultJSON: #"{"ok":true,"pointer":{"x":215,"y":206},"screenshot":"s.png"}"#)
        XCTAssertEqual(click?.x, 215); XCTAssertEqual(click?.y, 206); XCTAssertEqual(click?.clicked, true)
        XCTAssertEqual(PointerMapping.report(toolName: "move_mouse", resultJSON: #"{"ok":true,"pointer":{"x":1,"y":2}}"#)?.clicked, false)
        XCTAssertNil(PointerMapping.report(toolName: "click", resultJSON: #"{"error":"no display","pointer":{"x":1,"y":2}}"#))
        XCTAssertNil(PointerMapping.report(toolName: "type_text", resultJSON: #"{"ok":true,"pointer":{"x":1,"y":2}}"#))
        XCTAssertNil(PointerMapping.report(toolName: "click", resultJSON: "not json"))
    }
}
