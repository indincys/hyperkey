import XCTest
@testable import Hyper

final class LaunchIntentTests: XCTestCase {
    /// Clicking the app in Spotlight, the Dock or Finder arrives as an ordinary
    /// open-application event with nothing else attached. That is the case the window has
    /// to answer, because the status item may have been dragged off the menu bar.
    func testAnOpenApplicationEventSomebodyTriggeredIsAUserLaunch() {
        XCTAssertEqual(
            LaunchIntent.classify(
                isOpenApplicationEvent: true, launchedAsLoginItem: false, arguments: []
            ),
            .user
        )
    }

    /// The login item's launch is that same event with `kAELaunchedAsLogInItem` attached.
    /// Opening a window here would greet the user at every login with something they did
    /// not ask for.
    func testTheLoginItemLaunchIsNotAUserLaunch() {
        XCTAssertEqual(
            LaunchIntent.classify(
                isOpenApplicationEvent: true, launchedAsLoginItem: true, arguments: []
            ),
            .unattended
        )
    }

    /// A process started straight by `launchd` gets no open-application event at all.
    /// Nobody clicked anything, so it is not a request for a window.
    func testALaunchWithNoOpenApplicationEventWaitsForTheUser() {
        XCTAssertEqual(
            LaunchIntent.classify(
                isOpenApplicationEvent: false, launchedAsLoginItem: false, arguments: []
            ),
            .unattended
        )
        // Login-item flag or not, an absent event is an absent request.
        XCTAssertEqual(
            LaunchIntent.classify(
                isOpenApplicationEvent: false, launchedAsLoginItem: true, arguments: []
            ),
            .unattended
        )
    }

    /// The update swap and the move into /Applications both relaunch through
    /// LaunchServices, so they look exactly like a user launch from the outside. The
    /// argument is what keeps a silent update from putting its window on screen.
    func testOurOwnRelaunchIsNotAUserLaunch() {
        XCTAssertEqual(
            LaunchIntent.classify(
                isOpenApplicationEvent: true,
                launchedAsLoginItem: false,
                arguments: [LaunchIntent.backgroundArgument]
            ),
            .unattended
        )
    }

    /// `argv[0]` is the executable path and is always there; it must not be mistaken for
    /// the marker, and an unrelated argument must not change the answer.
    func testUnrelatedArgumentsDoNotChangeTheAnswer() {
        XCTAssertEqual(
            LaunchIntent.classify(
                isOpenApplicationEvent: true,
                launchedAsLoginItem: false,
                arguments: ["/Applications/Hyper.app/Contents/MacOS/Hyper", "-psn_0_1234"]
            ),
            .user
        )
    }

    /// The argument crosses a shell and `open --args` before it arrives, so it has to be a
    /// single token that survives that trip unquoted.
    func testTheBackgroundArgumentSurvivesTheShell() {
        XCTAssertEqual(LaunchIntent.backgroundArgument, "--hyper-background-launch")
        XCTAssertFalse(LaunchIntent.backgroundArgument.contains(" "))
        XCTAssertTrue(LaunchIntent.backgroundArgument.hasPrefix("--"))
    }

    func testTheDescriptionNamesTheTwoOutcomes() {
        XCTAssertEqual(LaunchIntent.user.description, "user")
        XCTAssertEqual(LaunchIntent.unattended.description, "unattended")
    }
}
