import XCTest
import LightTableEDR

final class EDRComponentTests: XCTestCase {
    func testDistributedBinaryLoadsItsPrecompiledKernel() {
        XCTAssertTrue(LTEDRIsReady(), "The EDR framework and its kernel resource must ship together")
    }
}
