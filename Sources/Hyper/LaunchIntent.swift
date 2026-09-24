import Foundation

/// Why this process is running, as far as the system is willing to say.
///
/// A menu-bar-only app normally has exactly one front door: the status item. macOS lets
/// the user drag that off the menu bar for good, and then the only way back to the window
/// is to launch the app again — so "somebody just asked for this app" has to be
/// distinguishable from "something started us on its own". Otherwise the app is
/// indistinguishable, from the inside, from an app that has simply died.
///
/// macOS does say which. An ordinary launch — Finder, Spotlight, the Dock, `open` —
/// arrives as a `kAEOpenApplication` Apple Event. The login item's launch is that same
/// event with `kAELaunchedAsLogInItem` attached, which is precisely what that key exists
/// for (it is documented as "probably shouldn't open up untitled documents").
enum LaunchIntent: Equatable, CustomStringConvertible {
    /// Somebody asked for the app, so it owes them a window.
    case user
    /// Nobody asked for a window: the login item, a process started straight by `launchd`,
    /// or one of Hyper's own relaunches.
    case unattended

    /// For the log line. "Launched by hand" and "started itself" are the two things worth
    /// being able to tell apart when someone reports that the window will not open.
    var description: String {
        switch self {
        case .user: return "user"
        case .unattended: return "unattended"
        }
    }

    /// The argument Hyper's own relaunches carry.
    ///
    /// An argument rather than a marker file, deliberately. A file left behind by a
    /// relaunch that then failed would swallow the next real click instead, and nothing
    /// would ever come along to clean it up; an argument only exists on the launch it was
    /// handed to.
    static let backgroundArgument = "--hyper-background-launch"

    /// Pure, so every way a launch can happen is testable without launching anything.
    ///
    /// `isOpenApplicationEvent` is false when there is no open-application event at all,
    /// which is how a process started directly by `launchd` arrives. Nobody clicked
    /// anything in that case, so it is not a request for a window either.
    static func classify(
        isOpenApplicationEvent: Bool,
        launchedAsLoginItem: Bool,
        arguments: [String]
    ) -> LaunchIntent {
        if arguments.contains(backgroundArgument) { return .unattended }
        guard isOpenApplicationEvent else { return .unattended }
        return launchedAsLoginItem ? .unattended : .user
    }
}
