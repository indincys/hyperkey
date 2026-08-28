import XCTest
@testable import Hyper

final class HyperHoldWatchdogPolicyTests: XCTestCase {
    func testPhysicalDownKeepsLongHoldAlive() {
        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: true, heldFor: 0.4))
        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: true, heldFor: 60))
    }

    func testPhysicalUpReleasesAtFirstWatchdogTick() {
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: false, heldFor: 0.4))
    }

    func testUnavailableRawStateHasBoundedFallback() {
        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: nil, heldFor: 0.4))
        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: nil, heldFor: 9.99))
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: nil, heldFor: 10))
    }
}
