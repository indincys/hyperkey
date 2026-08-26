import XCTest

@testable import Hyper

/// Version comparison is the single decision that makes the updater offer or withhold a
/// download, and the failure mode people notice — "1.0.10 is older than 1.0.9" — comes
/// from comparing the strings instead of the components.
final class UpdaterTests: XCTestCase {
    func testDoubleDigitComponentComparesNumerically() {
        XCTAssertTrue(Updater.isVersion("1.0.10", newerThan: "1.0.9"))
        XCTAssertFalse(Updater.isVersion("1.0.9", newerThan: "1.0.10"))
    }

    func testMoreSignificantComponentWins() {
        XCTAssertTrue(Updater.isVersion("1.1", newerThan: "1.0.9"))
        XCTAssertFalse(Updater.isVersion("1.0.9", newerThan: "1.1"))
        XCTAssertTrue(Updater.isVersion("2.0", newerThan: "1.99.99"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(Updater.isVersion("1.0.1", newerThan: "1.0"))
        XCTAssertFalse(Updater.isVersion("1.0", newerThan: "1.0.1"))
        // Trailing zeroes are the same version, not a newer one.
        XCTAssertFalse(Updater.isVersion("1.0.0", newerThan: "1.0"))
        XCTAssertFalse(Updater.isVersion("1.0", newerThan: "1.0.0"))
    }

    func testEqualVersionIsNotNewer() {
        XCTAssertFalse(Updater.isVersion("1.0.8", newerThan: "1.0.8"))
        XCTAssertFalse(Updater.isVersion(Hyper.version, newerThan: Hyper.version))
        XCTAssertTrue(Updater.isVersion("999.0.0", newerThan: Hyper.version))
    }

    func testNonNumericComponentDegradesToZeroRatherThanCrashing() {
        // A tag like "1.0.0-beta" must not trap; it simply reads as 1.0.0.
        XCTAssertFalse(Updater.isVersion("1.0.0-beta", newerThan: "1.0.0"))
        XCTAssertTrue(Updater.isVersion("1.1.0-beta", newerThan: "1.0.0"))
    }
}
