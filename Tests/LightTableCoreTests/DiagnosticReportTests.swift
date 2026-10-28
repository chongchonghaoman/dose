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
}
