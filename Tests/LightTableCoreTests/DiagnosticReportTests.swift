import XCTest
@testable import LightTableCore

final class DiagnosticReportTests: XCTestCase {
    private func report() -> DiagnosticReport {
        DiagnosticReport(sessionID: "123E4567-E89B-12D3-A456-426614174000",
            appVersion: "0.1.112", buildVersion: "112", macOSMajor: 15,
            macOSMinor: 1, macOSPatch: 0, architecture: "arm64")
    }

    func testReportRoundTripsWithAllowlistedEventNames() throws {
        var value = report()
        XCTAssertTrue(value.append(.init(elapsedMilliseconds: 12, name: .loupeEnabled)))

        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: value.encoded())
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.events.map(\.name), [.loupeEnabled])
    }

    func testEventsPastFifteenMinutesAreRejected() {
        var value = report()
        XCTAssertFalse(value.append(.init(elapsedMilliseconds: DiagnosticReport.maximumDurationMilliseconds + 1,
                                          name: .loupeEnabled)))
        XCTAssertTrue(value.events.isEmpty)
    }

    func testByteBudgetDropsOldEventsAndNeverReturnsOversizedData() throws {
        var value = report()
        let byteLimit = 1_000
        for index in 0..<80 {
            XCTAssertTrue(value.append(.init(elapsedMilliseconds: UInt64(index), name: .frameSummary,
                value1: Int64(index), value2: Int64(index + 1), value3: 2), maxBytes: byteLimit))
        }

        let data = try value.encoded(maxBytes: byteLimit)
        XCTAssertLessThanOrEqual(data.count, byteLimit)
        XCTAssertTrue(value.truncated)
        XCTAssertGreaterThan(value.events.first?.elapsedMilliseconds ?? 0, 0)
        XCTAssertEqual(value.events.last?.elapsedMilliseconds, 79)
    }

    func testEncodingRejectsMetadataThatCannotFitWithoutEvents() throws {
        let value = DiagnosticReport(sessionID: "123E4567-E89B-12D3-A456-426614174000",
            appVersion: String(repeating: "1", count: 5_000), buildVersion: "112",
            macOSMajor: 15, macOSMinor: 1, macOSPatch: 0, architecture: "arm64")
        XCTAssertThrowsError(try value.encoded(maxBytes: 100))
    }

    func testEventCountIsCappedAtServerLimitAndMarkedTruncated() throws {
        var value = report()
        for index in 0..<(DiagnosticReport.maximumEvents + 5) {
            XCTAssertTrue(value.append(.init(elapsedMilliseconds: UInt64(index), name: .loupeCancelled)))
        }
        XCTAssertEqual(value.events.count, DiagnosticReport.maximumEvents)
        XCTAssertTrue(value.truncated)
        XCTAssertEqual(value.events.first?.elapsedMilliseconds, 5)
        XCTAssertLessThanOrEqual(try value.encoded().count, DiagnosticReport.maximumEncodedBytes)
    }

    func testBoundaryReportWithMaximumEventsEncodesWithinByteLimit() throws {
        var value = report()
        for index in 0..<DiagnosticReport.maximumEvents {
            value.append(.init(elapsedMilliseconds: UInt64(index), name: .frameSummary,
                value1: 999_999_999, value2: -999_999_999, value3: 999_999_999))
        }
        XCTAssertFalse(value.truncated)
        XCTAssertLessThanOrEqual(try value.encoded().count, DiagnosticReport.maximumEncodedBytes)
    }

    func testNewReportsUseSchemaTwoWithSeparatedFrameUnits() throws {
        var value = report()
        XCTAssertEqual(value.schemaVersion, 2)
        XCTAssertTrue(value.append(.init(elapsedMilliseconds: 1, name: .frameSubmitSummary, value1: 60, value2: 120)))
        XCTAssertTrue(value.append(.init(elapsedMilliseconds: 2, name: .frameCompleteSummary, value1: 60, value2: 120, value3: 1800)))
        let json = String(data: try value.encoded(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("frame_submit_summary") && json.contains("frame_complete_summary"))
    }

    func testEdgeTrackerIgnoresRepeatedStates() {
        var tracker = DiagnosticEdgeTracker(initial: false)
        XCTAssertFalse(tracker.changed(to: false))
        XCTAssertTrue(tracker.changed(to: true))
        for _ in 0..<100 { XCTAssertFalse(tracker.changed(to: true)) }
        XCTAssertTrue(tracker.changed(to: false))
        XCTAssertFalse(tracker.changed(to: false))
    }
}
