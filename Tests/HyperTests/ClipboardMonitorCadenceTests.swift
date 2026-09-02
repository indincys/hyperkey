import AppKit
import XCTest

@testable import Hyper

/// The backstop cadence is a pure function of two inputs, so it is asserted directly
/// rather than by waiting on timers.
final class ClipboardMonitorCadenceTests: XCTestCase {
    private typealias Cadence = ClipboardMonitor.Cadence

    func testOpenPanelPollsFastRegardlessOfHowLongTheClipboardHasBeenStill() {
        for idle in [0, 1, 59, 60, 599, 600, 86_400] as [TimeInterval] {
            XCTAssertEqual(
                Cadence.interval(panelVisible: true, secondsSinceLastChange: idle),
                Cadence.watching,
                "an open panel must stay at the fast rate after \(idle)s of stillness"
            )
        }
    }

    func testHiddenPanelBacksOffAtSixtySecondsAndTenMinutes() {
        XCTAssertEqual(
            Cadence.interval(panelVisible: false, secondsSinceLastChange: 0), Cadence.base
        )
        XCTAssertEqual(
            Cadence.interval(panelVisible: false, secondsSinceLastChange: 59.9), Cadence.base
        )
        XCTAssertEqual(
            Cadence.interval(panelVisible: false, secondsSinceLastChange: 60), Cadence.idle
        )
        XCTAssertEqual(
            Cadence.interval(panelVisible: false, secondsSinceLastChange: 599.9), Cadence.idle
        )
        XCTAssertEqual(
            Cadence.interval(panelVisible: false, secondsSinceLastChange: 600), Cadence.dormant
        )
        XCTAssertEqual(
            Cadence.interval(panelVisible: false, secondsSinceLastChange: 86_400),
            Cadence.dormant
        )
    }

    func testCadenceIsMonotonicAndNeverSlowerThanTheDormantCeiling() {
        var previous: TimeInterval = 0
        for idle in stride(from: 0.0, through: 1_200.0, by: 7.5) {
            let value = Cadence.interval(panelVisible: false, secondsSinceLastChange: idle)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, Cadence.dormant)
            previous = value
        }
        // A clock that ran backwards must not be read as a decade of stillness.
        XCTAssertEqual(
            Cadence.interval(panelVisible: false, secondsSinceLastChange: -5_000),
            Cadence.base
        )
    }

    func testMonitorAdoptsTheFastRateWhenThePanelOpensAndTheSlowOneWhenItCloses() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, activeApplication: { nil }, now: { clock }
        )
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.currentPollInterval, Cadence.base)

        monitor.setPanelVisible(true)
        XCTAssertEqual(monitor.currentPollInterval, Cadence.watching)

        monitor.setPanelVisible(false)
        XCTAssertEqual(monitor.currentPollInterval, Cadence.base)

        // Ten minutes of stillness, observed the way the timer observes it.
        clock = clock.addingTimeInterval(Cadence.dormantThreshold + 1)
        monitor.setPanelVisible(true)
        monitor.setPanelVisible(false)
        XCTAssertEqual(monitor.currentPollInterval, Cadence.dormant)

        // A real copy pulls it straight back to the base rate.
        pasteboard.clearContents()
        pasteboard.setString("something new", forType: .string)
        monitor.check()
        XCTAssertEqual(monitor.currentPollInterval, Cadence.base)
    }

    /// `start()` resets the idle clock, which on its own would argue for the base rate.
    /// It must still ask whether the panel is up: a capture pause taken and released with
    /// the panel on screen has to come back polling fast, not at the backstop rate.
    func testRestartingWhileThePanelIsOpenResumesAtTheWatchingRate() {
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, activeApplication: { nil }, now: { clock }
        )
        monitor.start()
        defer { monitor.stop() }
        monitor.setPanelVisible(true)
        XCTAssertEqual(monitor.currentPollInterval, Cadence.watching)

        monitor.stop()
        monitor.start()
        XCTAssertEqual(
            monitor.currentPollInterval, Cadence.watching,
            "a restart with the panel still open must not drop to the backstop rate"
        )
    }

    func testWaitForChangeReturnsPromptlyAndReportsATimeoutWithoutBusyLooping() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, activeApplication: { nil })

        let observed = expectation(description: "change observed")
        var sawChange: Bool?
        monitor.waitForChange(timeout: 1) { changed in
            sawChange = changed
            observed.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pasteboard.clearContents()
            pasteboard.setString("copied", forType: .string)
        }
        wait(for: [observed], timeout: 2)
        XCTAssertEqual(sawChange, true)

        let timedOut = expectation(description: "timeout reported")
        let started = CFAbsoluteTimeGetCurrent()
        monitor.waitForChange(timeout: 0.2) { changed in
            XCTAssertFalse(changed)
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 2)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 0.6)
    }

    func testRestartingAfterALongSleepBeginsAtTheBaseRateNotTheDormantOne() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, activeApplication: { nil }, now: { clock }
        )
        monitor.start()
        XCTAssertEqual(monitor.currentPollInterval, Cadence.base)

        // Asleep, locked, or capture paused for an hour.
        monitor.suspend()
        clock = clock.addingTimeInterval(3_600)
        monitor.resume()
        XCTAssertEqual(
            monitor.currentPollInterval, Cadence.base,
            "waking up is exactly when the user is most likely to copy something"
        )

        // A plain stop/start after a long gap behaves the same way.
        monitor.stop()
        clock = clock.addingTimeInterval(Cadence.dormantThreshold * 3)
        monitor.start()
        XCTAssertEqual(monitor.currentPollInterval, Cadence.base)

        // The clock still backs off from that fresh baseline, so nothing is pinned fast.
        clock = clock.addingTimeInterval(Cadence.idleThreshold + 1)
        monitor.setPanelVisible(true)
        monitor.setPanelVisible(false)
        XCTAssertEqual(monitor.currentPollInterval, Cadence.idle)
        monitor.stop()
    }
}
