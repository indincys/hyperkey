import XCTest
@testable import Hyper

final class HyperHoldWatchdogPolicyTests: XCTestCase {
    func testPhysicalDownKeepsLongHoldAlive() {
        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: true, heldFor: 0.4))
        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: true, heldFor: 25))
    }

    /// A HID element latched at 1 by a device that disappeared mid-press reports a
    /// perfectly readable "down" forever. The ceiling is what stops that from latching
    /// four modifiers for the rest of the session.
    func testReadableDownStateStillReleasesAtTheAbsoluteCeiling() {
        let limit = HyperHoldWatchdogPolicy.absoluteHoldLimit

        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: true, heldFor: limit - 0.01
        ))
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(physicalKeyDown: true, heldFor: limit))
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: true, heldFor: limit + 60
        ))
    }

    /// Peek's contract is "it stays up as long as you hold the keys", so the ordinary
    /// ceiling would hide the window out from under someone still reading it.
    func testAnActivePeekGetsALongerLeashThanAnOrdinaryHold() {
        let ordinary = HyperHoldWatchdogPolicy.absoluteHoldLimit

        XCTAssertGreaterThan(HyperHoldWatchdogPolicy.peekHoldLimit, ordinary)
        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: true, heldFor: ordinary + 1, peekActive: true
        ))
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: true, heldFor: ordinary + 1, peekActive: false
        ))
    }

    /// The peek leash is longer, not infinite — a latched HID element during a peek is
    /// the same hazard as during any other hold.
    func testEvenAPeekIsReleasedAtItsOwnCeiling() {
        let limit = HyperHoldWatchdogPolicy.peekHoldLimit

        XCTAssertFalse(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: true, heldFor: limit - 0.01, peekActive: true
        ))
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: true, heldFor: limit, peekActive: true
        ))
    }

    /// A peek does not extend the fallback for an unreadable state: that timeout is
    /// about not trusting a guess, and holding a peek does not make the guess better.
    func testPeekDoesNotExtendTheUnknownStateFallback() {
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: nil,
            heldFor: HyperHoldWatchdogPolicy.unknownStateTimeout,
            peekActive: true
        ))
    }

    func testHoldLimitSelectsTheCeilingForTheCaller() {
        XCTAssertEqual(
            HyperHoldWatchdogPolicy.holdLimit(peekActive: false),
            HyperHoldWatchdogPolicy.absoluteHoldLimit
        )
        XCTAssertEqual(
            HyperHoldWatchdogPolicy.holdLimit(peekActive: true),
            HyperHoldWatchdogPolicy.peekHoldLimit
        )
    }

    /// The ceiling sits above the unknown-state fallback, so an unreadable state is
    /// still the first thing to give up on.
    func testAbsoluteCeilingSitsAboveTheUnknownStateFallback() {
        XCTAssertGreaterThan(
            HyperHoldWatchdogPolicy.absoluteHoldLimit,
            HyperHoldWatchdogPolicy.unknownStateTimeout
        )
        XCTAssertTrue(HyperHoldWatchdogPolicy.shouldRelease(
            physicalKeyDown: nil, heldFor: HyperHoldWatchdogPolicy.absoluteHoldLimit
        ))
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
