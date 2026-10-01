import Cocoa
import XCTest
@testable import Hyper

final class AppLauncherTests: XCTestCase {
    func testStandardHideShortcutMatchesPlainCommandHOnly() {
        XCTAssertTrue(AppLauncher.isStandardHideShortcut(character: "H", modifiers: 0))
        XCTAssertTrue(AppLauncher.isStandardHideShortcut(character: "h", modifiers: 0))
        XCTAssertFalse(AppLauncher.isStandardHideShortcut(character: "H", modifiers: 2))
        XCTAssertFalse(AppLauncher.isStandardHideShortcut(character: "Q", modifiers: 0))
        XCTAssertFalse(AppLauncher.isStandardHideShortcut(character: nil, modifiers: 0))
        XCTAssertFalse(AppLauncher.isStandardHideShortcut(character: "H", modifiers: nil))
    }

    // MARK: - Verified hide

    /// Dia acknowledges an `AXHidden` write and stays in front. The verdict has no
    /// "request accepted" input at all, so an acknowledgement cannot end the hide early.
    func testAnApplicationStillInFrontIsAskedAgainOnTheNextRung() {
        XCTAssertEqual(
            AppLauncher.hideVerdict(
                isTerminated: false, isHidden: false, isFrontmost: true, rungsRemain: true
            ),
            .escalate
        )
    }

    /// Sitting behind another application is the inconsistent outcome the toggle exists
    /// to avoid, not a successful hide.
    func testAnApplicationBehindAnotherOneIsNotTreatedAsHidden() {
        XCTAssertEqual(
            AppLauncher.hideVerdict(
                isTerminated: false, isHidden: false, isFrontmost: false, rungsRemain: true
            ),
            .escalate
        )
    }

    func testAHiddenOrTerminatedApplicationEndsTheHide() {
        for rungsRemain in [true, false] {
            XCTAssertEqual(
                AppLauncher.hideVerdict(
                    isTerminated: false, isHidden: true, isFrontmost: false,
                    rungsRemain: rungsRemain
                ),
                .done
            )
            XCTAssertEqual(
                AppLauncher.hideVerdict(
                    isTerminated: true, isHidden: false, isFrontmost: true,
                    rungsRemain: rungsRemain
                ),
                .done
            )
        }
    }

    func testOutOfRungsAndStillInFrontFallsBackToThePreviousApplication() {
        XCTAssertEqual(
            AppLauncher.hideVerdict(
                isTerminated: false, isHidden: false, isFrontmost: true, rungsRemain: false
            ),
            .activateFallback
        )
    }

    /// Something else came forward in the meantime; pulling focus off it to cover for a
    /// failed hide would be worse than the failure.
    func testOutOfRungsButNoLongerInFrontLeavesFocusAlone() {
        XCTAssertEqual(
            AppLauncher.hideVerdict(
                isTerminated: false, isHidden: false, isFrontmost: false, rungsRemain: false
            ),
            .leftVisible
        )
    }

    func testEveryRungIsReachedInOrderAndTheLadderEnds() {
        var visited: [AppLauncher.HideRung] = []
        var rung: AppLauncher.HideRung? = AppLauncher.HideRung.allCases.first
        while let current = rung {
            visited.append(current)
            rung = current.next
        }

        XCTAssertEqual(visited, [.processRequests, .menuCommand])
        XCTAssertEqual(visited, AppLauncher.HideRung.allCases)
    }

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

    // MARK: - Cold-start de-duplication

    func testFirstPressForAnApplicationIsNeverIgnored() {
        XCTAssertFalse(
            AppLauncher.shouldIgnoreRepeatLaunch(startedAt: nil, now: Date())
        )
    }

    func testRepeatPressDuringAColdLaunchIsIgnored() {
        let started = Date()

        XCTAssertTrue(AppLauncher.shouldIgnoreRepeatLaunch(
            startedAt: started, now: started
        ))
        XCTAssertTrue(AppLauncher.shouldIgnoreRepeatLaunch(
            startedAt: started,
            now: started.addingTimeInterval(AppLauncher.launchInFlightTimeout - 0.01)
        ))
    }

    /// A launch that never reports back must not disable its binding for the session.
    func testStaleInFlightEntryStopsSuppressingPressesAfterTheTimeout() {
        let started = Date()

        XCTAssertFalse(AppLauncher.shouldIgnoreRepeatLaunch(
            startedAt: started,
            now: started.addingTimeInterval(AppLauncher.launchInFlightTimeout)
        ))
        XCTAssertFalse(AppLauncher.shouldIgnoreRepeatLaunch(
            startedAt: started,
            now: started.addingTimeInterval(AppLauncher.launchInFlightTimeout + 600)
        ))
    }

    /// A clock that jumped backwards would otherwise wedge the binding until the wall
    /// clock caught up. Launching twice is the recoverable side of that trade.
    func testTimestampInTheFutureDoesNotSuppressPresses() {
        let now = Date()

        XCTAssertFalse(AppLauncher.shouldIgnoreRepeatLaunch(
            startedAt: now.addingTimeInterval(60), now: now
        ))
    }

    func testTimeoutIsConfigurablePerCall() {
        let started = Date()

        XCTAssertTrue(AppLauncher.shouldIgnoreRepeatLaunch(
            startedAt: started, now: started.addingTimeInterval(0.5), timeout: 1
        ))
        XCTAssertFalse(AppLauncher.shouldIgnoreRepeatLaunch(
            startedAt: started, now: started.addingTimeInterval(1.5), timeout: 1
        ))
    }

    /// A running application is the repeat-press case: registering it in flight would
    /// swallow the next eight seconds of presses on the binding being pressed.
    func testOnlyAColdStartIsRegisteredAsInFlight() {
        XCTAssertEqual(
            AppLauncher.coldLaunchToTrack(bundleID: "com.example.app", isAlreadyRunning: false),
            "com.example.app"
        )
        XCTAssertNil(
            AppLauncher.coldLaunchToTrack(bundleID: "com.example.app", isAlreadyRunning: true)
        )
    }

    /// A path target that resolves to no bundle ID has no key to register under.
    func testTargetWithoutABundleIdentifierIsNeverRegistered() {
        XCTAssertNil(AppLauncher.coldLaunchToTrack(bundleID: nil, isAlreadyRunning: false))
        XCTAssertNil(AppLauncher.coldLaunchToTrack(bundleID: nil, isAlreadyRunning: true))
    }

    func testRunningApplicationReceivesReopenEvent() throws {
        let configuration = AppLauncher.activationConfiguration(runningProcessIdentifier: 4242)
        let event = try XCTUnwrap(configuration.appleEvent)

        XCTAssertTrue(configuration.activates)
        XCTAssertEqual(event.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(event.eventID, AEEventID(kAEReopenApplication))
    }
}
