import AppKit
import XCTest

@testable import Hyper

/// When the preview card follows the pointer, and when it holds.
///
/// Two requirements pull against each other, and this file is the record of the
/// compromise between them.
///
/// The card has to be *reachable*. When it opens on the far side of the list it can only
/// be got at by crossing the rows between, and a card that followed every row crossed
/// would be showing something else by the time the pointer arrived — the entry being
/// travelled to would be gone.
///
/// And it has to be *evenly* responsive. The first answer to the reachability problem held
/// the card by the direction the pointer was moving, which made the identical gesture fast
/// one way and slow the other: a quarter-second hold towards a card on one side, instant
/// following away from it. That is the "时快时慢" this replaced.
///
/// The rule now is symmetric and has nothing to do with sides or directions: the card
/// follows the row the pointer *settles* on. Moving across rows never retargets; stopping
/// on one does, after a delay short enough to read as immediate.
///
/// Nothing here races a stopwatch. Every `asyncAfter` the model schedules is delivered on
/// the main queue, and the tests run on the main thread, so a scheduled move *cannot* fire
/// while the test is not running the run loop — which makes "has not happened yet" a
/// synchronous assertion, and "has happened" a poll to a generous deadline.
final class ClipboardPanelTravelTests: XCTestCase {
    private var roots: [URL] = []
    private var managers: [ClipboardManager] = []

    override func tearDown() {
        managers.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    /// A model holding exactly the records given, with a pointer the test drives.
    private func hoveringModel(_ records: [ClipRecord], label: String) -> ClipboardPanelModel {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-travel-\(label)-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(location)
        let store = ClipStore(root: location)
        let loaded = expectation(description: "store loaded")
        let filters = expectation(description: "smart filters loaded")
        store.whenLoaded { loaded.fulfill() }
        store.whenSmartFiltersLoaded { filters.fulfill() }
        wait(for: [loaded, filters], timeout: 5)

        let queue = PasteQueue(storeURL: location.appendingPathComponent("queue.json"))
        queue.restore()
        let manager = ClipboardManager(store: store, queue: queue)
        managers.append(manager)

        var completions: [(Result<ClipSearchOutcome, ClipQueryParseError>) -> Void] = []
        let model = ClipboardPanelModel(
            manager: manager,
            searchExecutor: { _, _, completion in
                completions.append(completion)
                return ClipSearchCancellationToken()
            }
        )
        model.query = "种子"
        settle { !completions.isEmpty }
        completions.removeLast()(
            .success(ClipSearchOutcome(records: records, terms: [], contexts: [:]))
        )
        settle { model.results.count == records.count }
        // Far from wherever the real pointer is, so the "has the pointer really moved
        // since the panel opened" check passes on the first hover.
        model.pointerLocation = {
            NSPoint(x: NSEvent.mouseLocation.x + 400, y: NSEvent.mouseLocation.y + 400)
        }
        return model
    }

    private func images(_ count: Int) -> [ClipRecord] {
        let now = Date()
        return (0..<count).map { index in
            let id = UUID()
            return ClipRecord(
                id: id, createdAt: now, kind: .image, preview: "图片 \(index)",
                digest: "travel-\(id.uuidString)", byteSize: 1024,
                sourceBundleID: "com.example.shot", sourceName: "Shot",
                hasThumbnail: true, pixelWidth: 800, pixelHeight: 600
            )
        }
    }

    /// Polls the run loop until the predicate holds, or fails the test.
    private func settle(
        _ predicate: () -> Bool, timeout: TimeInterval = 2, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func runLoop(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Puts the card on a row and waits for it to be there.
    private func rest(on index: Int, in model: ClipboardPanelModel) {
        model.hover(index)
        settle { model.previewIndex == index }
        XCTAssertEqual(model.previewIndex, index)
    }

    // MARK: - Settling

    /// The card is not retargeted the instant the pointer touches a row — that is what
    /// makes it unreachable — but it does follow the row the pointer comes to rest on.
    func testTheCardFollowsTheRowThePointerSettlesOn() {
        let model = hoveringModel(images(3), label: "settle")
        model.hover(1)
        // No run loop has run since the hover, so the scheduled move cannot have fired.
        XCTAssertNil(model.previewIndex, "not the instant the pointer arrives")

        settle { model.previewIndex == 1 }
        XCTAssertEqual(model.previewIndex, 1)
    }

    /// The highlight is not the card. The row under the pointer lights up at once, because
    /// it has to be lit before the eye arrives; only the preview waits.
    func testTheHighlightMovesAtOnceEvenThoughTheCardWaits() {
        let model = hoveringModel(images(3), label: "highlight")
        model.hover(2)
        XCTAssertEqual(model.selectedIndex, 2, "the row is selected immediately")
        XCTAssertNil(model.previewIndex, "and the card has not caught up yet")
    }

    /// Stepping from a row onto its neighbour: the highlight follows at once, the card
    /// moves on behind it.
    func testBothTheHighlightAndTheCardFollowARowChange() {
        let model = hoveringModel(images(4), label: "step")
        rest(on: 0, in: model)

        model.hover(1)
        XCTAssertEqual(model.selectedIndex, 1)
        settle { model.previewIndex == 1 }
        XCTAssertEqual(model.previewIndex, 1)
    }

    // MARK: - The reported case

    /// Three pictures in a row, the rightmost hovered, the card on the far side. Crossing
    /// the row towards the card must not change what the card shows.
    func testCrossingTheRowHoldsTheHoveredPicture() {
        let model = hoveringModel(images(3), label: "cross")
        rest(on: 2, in: model)

        // Crossing the two pictures between it and the card. Each hover is asserted with
        // no run loop in between, so these are "it did not retarget on arrival" — which is
        // the whole of what a crossing does.
        for index in [1, 0] {
            model.hover(index)
            XCTAssertEqual(model.previewIndex, 2, "the card must hold while the pointer travels")
        }
    }

    /// Reaching the card ends the journey: the move pending for a row crossed on the way
    /// is dropped, so the card keeps the entry that was travelled to — long after that
    /// pending move would otherwise have fired.
    func testArrivingAtTheCardDropsThePendingMove() {
        let model = hoveringModel(images(3), label: "arrive")
        rest(on: 2, in: model)

        model.hover(1)
        model.setPointerInPreview(true)
        runLoop(0.4)

        XCTAssertEqual(model.previewIndex, 2, "the card keeps what it was reached for")
        XCTAssertTrue(model.pointerInPreview)
    }

    /// And when the pointer comes back to the list, the card follows again — the hold is
    /// not a mode that has to be escaped.
    func testTheCardFollowsAgainAfterLeavingTheCard() {
        let model = hoveringModel(images(3), label: "return")
        rest(on: 2, in: model)
        model.hover(1)
        model.setPointerInPreview(true)
        runLoop(0.2)
        XCTAssertEqual(model.previewIndex, 2)

        model.setPointerInPreview(false)
        model.hover(0)
        settle { model.previewIndex == 0 }
        XCTAssertEqual(model.previewIndex, 0)
    }

    // MARK: - Even in every direction

    /// The point of replacing the directional hold: the same crossing costs the same
    /// whichever way it goes, and whichever side the card is on.
    func testCrossingInEitherDirectionHoldsTheSameWay() {
        let model = hoveringModel(images(6), label: "directions")
        rest(on: 2, in: model)

        // Rightward, then leftward, then rightward again — none of them retargets on
        // arrival, and each settles once the pointer stops.
        for index in [3, 4, 5, 4, 3, 2, 1] {
            model.hover(index)
            XCTAssertEqual(model.previewIndex, 2, "no retarget while crossing to \(index)")
        }
        settle { model.previewIndex == 1 }
        XCTAssertEqual(model.previewIndex, 1, "and it follows where the pointer stopped")
    }

    /// Nothing about the card's side takes part any more: the model is never told it, and
    /// the same sequence holds whichever side a card would have landed on.
    func testBehaviourDoesNotDependOnWhichSideTheCardIsOn() {
        let model = hoveringModel(images(3), label: "sides")
        rest(on: 2, in: model)
        for index in [1, 0, 1, 2] {
            model.hover(index)
            XCTAssertEqual(model.previewIndex, 2)
        }
    }

    // MARK: - Leaving the list

    /// Stepping straight from one row onto the next must not read as leaving the list just
    /// because the card has not caught up yet. SwiftUI does not promise which of the two
    /// hover callbacks runs first, so both orders have to work.
    func testSteppingBetweenRowsKeepsTheListPointerInside() {
        for reverse in [false, true] {
            let model = hoveringModel(images(4), label: "step-\(reverse)")
            rest(on: 0, in: model)
            XCTAssertTrue(model.pointerOnList)

            if reverse {
                model.hoverEnded(0)
                model.hover(1)
            } else {
                model.hover(1)
                model.hoverEnded(0)
            }

            XCTAssertTrue(
                model.pointerOnList,
                "reverse=\(reverse): moving onto the next row is not leaving the list"
            )
            settle { model.previewIndex == 1 }
            XCTAssertEqual(model.previewIndex, 1, "reverse=\(reverse)")
        }
    }

    /// Leaving the list for somewhere that is not a row does let the card go.
    func testLeavingTheListReleasesTheCard() {
        let model = hoveringModel(images(3), label: "leave")
        rest(on: 1, in: model)
        XCTAssertTrue(model.pointerOnList)

        model.hoverEnded(1)
        XCTAssertFalse(model.pointerOnList)
        XCTAssertFalse(model.previewOpen)
    }

    /// A stale `hoverEnded` from a row the pointer has already left must not clear the
    /// state the new row just set.
    func testAStaleHoverEndedIsIgnored() {
        let model = hoveringModel(images(3), label: "stale")
        rest(on: 0, in: model)

        model.hover(2)
        model.hoverEnded(0)
        XCTAssertTrue(model.pointerOnList, "row 0 is not where the pointer is any more")
        settle { model.previewIndex == 2 }
        XCTAssertEqual(model.previewIndex, 2)
    }

    /// The pending move is dropped when the panel is reset, so a card cannot appear on a
    /// stale row at the next opening.
    func testResetDropsAPendingMove() {
        let model = hoveringModel(images(3), label: "reset")
        model.hover(2)
        model.reset()
        runLoop(0.3)
        XCTAssertNil(model.previewIndex)
    }

    /// A row merely crossed never becomes the previewed one, so nothing was ever asked for
    /// on its behalf.
    func testCrossingManyRowsOnlyEverPreviewsTheOneStoppedOn() {
        let model = hoveringModel(images(12), label: "sweep")
        rest(on: 0, in: model)

        for index in 1..<12 { model.hover(index) }
        // Only the last row the pointer touched is pending; none of the eleven before it
        // can be delivered, because each hover cancelled the one before.
        settle { model.previewIndex == 11 }
        XCTAssertEqual(model.previewIndex, 11)
    }
}
