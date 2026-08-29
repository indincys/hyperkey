import Cocoa
import XCTest
@testable import Hyper

final class AppLauncherTests: XCTestCase {
    func testColdApplicationKeepsDefaultLaunchEvent() {
        let configuration = AppLauncher.activationConfiguration(runningProcessIdentifier: nil)

        XCTAssertTrue(configuration.activates)
        XCTAssertNil(configuration.appleEvent)
    }

    func testRunningApplicationReceivesReopenEvent() throws {
        let configuration = AppLauncher.activationConfiguration(runningProcessIdentifier: 4242)
        let event = try XCTUnwrap(configuration.appleEvent)

        XCTAssertTrue(configuration.activates)
        XCTAssertEqual(event.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(event.eventID, AEEventID(kAEReopenApplication))
    }
}
