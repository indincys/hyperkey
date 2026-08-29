import Cocoa
import XCTest
@testable import Hyper

final class AppLauncherTests: XCTestCase {
    func testPendingReturnCoversRapidRepeatBeforeActivationConfirmation() {
        var returns = PendingApplicationReturns<String, String>()

        returns.remember("previous", for: "target")

        XCTAssertEqual(returns.take(for: "target"), "previous")
        XCTAssertNil(returns.take(for: "target"))
    }

    func testConfirmedActivationDiscardsStaleReturnDestination() {
        var returns = PendingApplicationReturns<String, String>()

        returns.remember("original", for: "target")
        returns.confirmActivation(of: "target")

        XCTAssertNil(returns.take(for: "target"))
    }

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
