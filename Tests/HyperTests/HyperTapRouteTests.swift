import CoreGraphics
import XCTest
@testable import Hyper

/// Pins the routing rule the event tap applies before it touches any state.
final class HyperTapRouteTests: XCTestCase {
    private func route(
        _ type: CGEventType,
        _ key: CGKeyCode,
        enabled: Bool = true,
        synthetic: Bool = false
    ) -> HyperTap.Route {
        HyperTap.routeDecision(type: type, key: key, enabled: enabled, isSynthetic: synthetic)
    }

    private let ordinaryKey = Keys.byName["k"]!

    // MARK: - Paused

    /// Caps Lock stays remapped to F19 while Hyper is paused, so letting the trigger
    /// through would deliver a bare F19 to whatever is in front.
    func testPausedSwallowsTheTriggerKeyInsteadOfLeakingF19() {
        XCTAssertEqual(route(.keyDown, Keys.hyperTrigger, enabled: false), .swallowTrigger)
        XCTAssertEqual(route(.keyUp, Keys.hyperTrigger, enabled: false), .swallowTrigger)
    }

    func testPausedPassesEveryOtherKeyThrough() {
        XCTAssertEqual(route(.keyDown, ordinaryKey, enabled: false), .passThrough)
        XCTAssertEqual(route(.keyUp, ordinaryKey, enabled: false), .passThrough)
        XCTAssertEqual(route(.flagsChanged, Keys.command, enabled: false), .passThrough)
    }

    /// A `flagsChanged` carrying the trigger's key code is not a trigger press, so the
    /// swallow must not reach it — a modifier eaten here would latch downstream.
    func testPausedPassesFlagsChangedThroughEvenForTheTriggerKeyCode() {
        XCTAssertEqual(route(.flagsChanged, Keys.hyperTrigger, enabled: false), .passThrough)
    }

    /// Pausing lands wherever the user's hands are. A key-up swallowed while a hold is
    /// still latched has to unwind it first, or `hyperDown` stays true with no event left
    /// that can clear it and every keystroke reads as part of a chord.
    func testPausedKeyUpUnwindsAHoldThatIsStillLatched() {
        XCTAssertTrue(HyperTap.pausedTriggerNeedsRelease(type: .keyUp, hyperDown: true))
    }

    func testPausedTriggerDoesNotUnwindWhenThereIsNoHold() {
        XCTAssertFalse(HyperTap.pausedTriggerNeedsRelease(type: .keyUp, hyperDown: false))
        // A key-*down* while paused never starts a hold, so there is nothing to unwind
        // even if stale state claims otherwise.
        XCTAssertFalse(HyperTap.pausedTriggerNeedsRelease(type: .keyDown, hyperDown: true))
        XCTAssertFalse(HyperTap.pausedTriggerNeedsRelease(type: .keyDown, hyperDown: false))
    }

    // MARK: - Synthetic

    func testSyntheticEventsAlwaysPassThrough() {
        XCTAssertEqual(route(.keyDown, ordinaryKey, synthetic: true), .passThrough)
        XCTAssertEqual(route(.flagsChanged, Keys.shift, synthetic: true), .passThrough)
        // Including the trigger, and including while paused: reprocessing anything we
        // posted ourselves is how a modifier sequence would feed itself.
        XCTAssertEqual(route(.keyDown, Keys.hyperTrigger, synthetic: true), .passThrough)
        XCTAssertEqual(
            route(.keyUp, Keys.hyperTrigger, enabled: false, synthetic: true), .passThrough
        )
    }

    // MARK: - Running

    func testEnabledRoutesTheTriggerToPressAndRelease() {
        XCTAssertEqual(route(.keyDown, Keys.hyperTrigger), .trigger(down: true))
        XCTAssertEqual(route(.keyUp, Keys.hyperTrigger), .trigger(down: false))
    }

    func testEnabledSendsEverythingElseToTheStatefulPath() {
        XCTAssertEqual(route(.keyDown, ordinaryKey), .process)
        XCTAssertEqual(route(.keyUp, ordinaryKey), .process)
        XCTAssertEqual(route(.flagsChanged, Keys.command), .process)
    }
}
