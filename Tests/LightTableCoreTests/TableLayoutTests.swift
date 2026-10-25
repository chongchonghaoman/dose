import XCTest
@testable import LightTableCore

final class TableLayoutTests: XCTestCase {
    let photo = URL(fileURLWithPath: "/tmp/lighttable/photo.jpg")

    func testDropKeepsLocationAndDoesNotArrangeExistingSlides() {
        var table = TableLayout()
        let a = table.place(photo, x: 0.27, y: 0.61)
        table.place(URL(fileURLWithPath: "/tmp/second.jpg"), x: 0.75, y: 0.2)
        XCTAssertEqual(table.slides.first?.id, a)
        XCTAssertEqual(table.slides.first?.x, 0.27)
        XCTAssertEqual(table.slides.first?.y, 0.61)
    }

    func testRepeatedDropMovesExistingSlideAndRaisesIt() {
        var table = TableLayout()
        let a = table.place(photo, x: 0.2, y: 0.2)
        table.place(URL(fileURLWithPath: "/tmp/second.jpg"), x: 0.7, y: 0.7)
        XCTAssertEqual(table.place(photo, x: 0.4, y: 0.6), a)
        XCTAssertEqual(table.slides.count, 2)
        XCTAssertEqual(table.slides.last?.id, a)
        XCTAssertEqual(table.slides.last?.x, 0.4)
    }

    func testInvalidTransformCannotLoseSlide() {
        var table = TableLayout()
        let id = table.place(photo, x: .nan, y: .infinity)
        table.update(id) { $0.width = -99; $0.angle = .infinity; $0.x = -20; $0.y = 999 }
        let slide = table.slides[0]
        XCTAssertEqual(slide.x, -20); XCTAssertEqual(slide.y, 999)
        XCTAssertEqual(slide.width, 0.12); XCTAssertEqual(slide.angle, 0)
    }

    func testLayoutRoundTripPreservesRotationScaleAndOrder() throws {
        var table = TableLayout()
        let id = table.place(photo, x: 0.23, y: 0.73)
        table.update(id) { $0.width = 0.6; $0.angle = 37 }
        let data = try JSONEncoder().encode(table)
        XCTAssertEqual(try JSONDecoder().decode(TableLayout.self, from: data).sanitized(), table)
    }

    func testRemoveAndClearDoNotTouchOriginalFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var table = TableLayout()
        table.remove(table.place(file, x: 0.5, y: 0.5))
        table.place(file, x: 0.5, y: 0.5); table.clear()
        XCTAssertTrue(table.slides.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }

    func testResizePreservesNormalizedLayout() {
        let small = TableCoordinates.fit(width: 800, height: 700)
        let large = TableCoordinates.fit(width: 1600, height: 1400)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 700)
        XCTAssertGreaterThan(large.width, small.width)
    }

    func testLoupeCoordinatesInvertQuarterTurn() {
        let p = TableCoordinates.localPoint(x: 100, y: 130, centerX: 100, centerY: 100, angle: 90)
        XCTAssertEqual(p.x, 30, accuracy: 1e-9); XCTAssertEqual(p.y, 0, accuracy: 1e-9)
    }
}
