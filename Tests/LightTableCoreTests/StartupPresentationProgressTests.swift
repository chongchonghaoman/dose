import XCTest
@testable import LightTableCore

final class StartupPresentationProgressTests: XCTestCase {
    func testPhotoCountBeginsAtHalfwayForEveryLibrarySize() {
        for total in [1, 20, 22, 100] {
            XCTAssertNil(StartupPresentationProgress.photoCount(total: total, progress: 0.499))
            XCTAssertEqual(StartupPresentationProgress.photoCount(total: total, progress: 0.5), 1)
            XCTAssertEqual(StartupPresentationProgress.photoCount(total: total, progress: 1), total)
        }
    }

    func testEntireCountOccupiesOnlyTheSecondHalf() {
        XCTAssertEqual(StartupPresentationProgress.photoCount(total: 20, progress: 0.75), 10)
        XCTAssertEqual(StartupPresentationProgress.photoCount(total: 22, progress: 0.75), 11)
        XCTAssertEqual(StartupPresentationProgress.photoCount(total: 100, progress: 0.75), 50)
        XCTAssertEqual(StartupPresentationProgress.photoCount(total: 100, progress: 0.9), 80)
    }

    func testRealWorkDrivesProgressWithoutFixedDuration() {
        XCTAssertEqual(StartupPresentationProgress.preparation(completed: 10, total: 20, elapsed: 0), 0.5)
        XCTAssertEqual(StartupPresentationProgress.preparation(completed: 10, total: 20, elapsed: 200), 0.5)
        XCTAssertEqual(StartupPresentationProgress.preparation(completed: 10, total: 100, elapsed: 200), 0.1)
        XCTAssertLessThanOrEqual(StartupPresentationProgress.preparation(completed: 0, total: 100, elapsed: 3600), 0.08)
        XCTAssertLessThan(StartupPresentationProgress.preparation(completed: 100, total: 100, elapsed: 3600), 1)
    }

    func testCounterNeverMovesBackwardsOrExceedsTheTotal() {
        for total in [1, 20, 22, 100] {
            var previousCount = 0
            var previousProgress = 0.0
            for step in 0...100 {
                let progress = StartupPresentationProgress.preparation(
                    completed: total * step / 100, total: total, elapsed: Double(step))
                XCTAssertGreaterThanOrEqual(progress, previousProgress)
                XCTAssertLessThan(progress, 1)
                previousProgress = progress
                let count = StartupPresentationProgress.photoCount(total: total, progress: Double(step) / 100) ?? 0
                XCTAssertGreaterThanOrEqual(count, previousCount)
                XCTAssertLessThanOrEqual(count, total)
                previousCount = count
            }
        }
        XCTAssertNil(StartupPresentationProgress.photoCount(total: 0, progress: 1))
        XCTAssertNil(StartupPresentationProgress.photoCount(total: 22, progress: .nan))
        XCTAssertEqual(StartupPresentationProgress.preparation(completed: 0, total: 0, elapsed: 1), 0)
        XCTAssertEqual(StartupPresentationProgress.preparation(completed: -1, total: 20, elapsed: .nan), 0)
    }
}
