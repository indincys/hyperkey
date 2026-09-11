import AppKit
import XCTest

@testable import Hyper

/// Reaching the preview card when it is placed on the far side of the list.
///
/// The bug this exists for: three pictures in a row, the rightmost one hovered, and the
/// card opens to the *left* because there is no room on the right. Crossing to the card
/// means crossing two other pictures, and following them changed the card before the
/// pointer ever got there — so the card could not be reached at all.
///
/// The rule now is that the card holds the entry it is showing while the pointer is
/// heading towards it, and lets go the moment the pointer stops heading anywhere.
final class ClipboardPanelTravelTests: XCTestCase {
    private final class Harness {
        var completions: [(Result<ClipSearchOutcome, ClipQueryParseError>) -> Void] = []
    }

    private var roots: [URL] = []
    private var managers: [ClipboardManager] = []

    override func tearDown() {
        managers.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    /// A model holding exactly the records given, plus a pointer the test drives.
    ///
    /// The pointer starts far from wherever the real mouse is, which is what makes the
    /// model's "the pointer has really moved since the panel opened" check pass on the
    /// first hover.
    private func travellingModel(
        _ records: [ClipRecord], label: String
    ) -> (ClipboardPanelModel, Harness, (NSPoint) -> Void) {
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

        let harness = Harness()
        let model = ClipboardPanelModel(
            manager: manager,
            searchExecutor: { _, _, completion in
                harness.completions.append(completion)
                return ClipSearchCancellationToken()
            }
        )
        model.query = "种子"
        settle { !harness.completions.isEmpty }
        harness.completions.removeLast()(
            .success(ClipSearchOutcome(records: records, terms: [], contexts: [:]))
        )
        settle { model.results.count == records.count }

        let away = NSPoint(x: NSEvent.mouseLocation.x + 400, y: NSEvent.mouseLocation.y + 400)
        var pointer = away
        model.pointerLocation = { pointer }
        return (model, harness, { pointer = $0 })
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

    private func settle(_ predicate: () -> Bool, timeout: TimeInterval = 2) {
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

    // MARK: - The reported case

    /// Three pictures in a row, the rightmost hovered, card on the left. Crossing the row
    /// must not change what the card shows.
    func testCrossingTheRowTowardsACardOnTheLeftHoldsTheHoveredPicture() {
        let (model, _, setPointer) = travellingModel(images(3), label: "cross-left")
        model.setPreviewCardSide(onLeft: true)

        var pointer = NSPoint(x: 600, y: 400)
        setPointer(pointer)
        model.hover(2)
        XCTAssertEqual(model.previewIndex, 2, "the rightmost picture is previewed")
        XCTAssertEqual(model.selectedIndex, 2)

        // Crossing left over the two pictures between it and the card.
        pointer.x -= 60; setPointer(pointer); model.hover(1)
        XCTAssertEqual(model.previewIndex, 2, "the card must hold while the pointer travels")
        XCTAssertEqual(model.selectedIndex, 2, "and the selection with it")

        pointer.x -= 60; setPointer(pointer); model.hover(0)
        XCTAssertEqual(model.previewIndex, 2)
        XCTAssertEqual(model.selectedIndex, 2)
    }

    /// The card still follows a pointer that just moves onto a neighbour — the hold is
    /// only about heading for the card, not a freeze.
    func testMovingAwayFromTheCardRetargetsImmediately() {
        let (model, _, setPointer) = travellingModel(images(6), label: "away-left")
        model.setPreviewCardSide(onLeft: true)

        var pointer = NSPoint(x: 400, y: 400)
        setPointer(pointer)
        model.hover(1)

        pointer.x += 60; setPointer(pointer)
        model.hover(2)
        XCTAssertEqual(model.previewIndex, 2, "moving away from a left-hand card is not travelling")
    }

    /// The hold is not permanent: resting on another picture previews it.
    func testRestingOnAnotherPictureLetsThePreviewFollow() {
        let (model, _, setPointer) = travellingModel(images(3), label: "rest")
        model.setPreviewCardSide(onLeft: true)

        var pointer = NSPoint(x: 600, y: 400)
        setPointer(pointer)
        model.hover(2)

        pointer.x -= 60; setPointer(pointer)
        model.hover(1)
        XCTAssertEqual(model.previewIndex, 2, "held while travelling")

        // The pointer stops. It is looking at picture 1 now, so that is what it gets.
        runLoop(0.6)
        XCTAssertEqual(model.previewIndex, 1)
        XCTAssertEqual(model.selectedIndex, 1)
    }

    /// A slow crossing is still a crossing: as long as the pointer keeps moving towards
    /// the card, the hold is renewed rather than expiring mid-journey.
    func testAContinuingCrossingKeepsRenewingTheHold() {
        let (model, _, setPointer) = travellingModel(images(3), label: "slow")
        model.setPreviewCardSide(onLeft: true)

        var pointer = NSPoint(x: 600, y: 400)
        setPointer(pointer)
        model.hover(2)

        pointer.x -= 60; setPointer(pointer)
        model.hover(1)

        // Still moving towards the card when the first hold would have expired.
        pointer.x -= 60; setPointer(pointer)
        runLoop(0.35)
        XCTAssertEqual(model.previewIndex, 2, "still on the way to the card")

        // Now the pointer stops on picture 1.
        runLoop(0.6)
        XCTAssertEqual(model.previewIndex, 1, "and follows once it has stopped")
    }

    /// Arriving at the card ends the hold, so coming back to the list starts fresh.
    func testArrivingAtTheCardEndsTheHold() {
        let (model, _, setPointer) = travellingModel(images(3), label: "arrive")
        model.setPreviewCardSide(onLeft: true)

        var pointer = NSPoint(x: 600, y: 400)
        setPointer(pointer)
        model.hover(2)

        pointer.x -= 60; setPointer(pointer)
        model.hover(1)
        model.setPointerInPreview(true)
        XCTAssertTrue(model.pointerInPreview)

        // The pointer sits on the card; nothing should release the hold behind its back.
        runLoop(0.6)
        XCTAssertEqual(model.previewIndex, 2, "the card keeps showing what it was reached for")
    }

    /// The same traversal problem exists in the other direction, and gets the same rule.
    func testTheHoldWorksWithTheCardOnTheRightToo() {
        let (model, _, setPointer) = travellingModel(images(3), label: "right")
        model.setPreviewCardSide(onLeft: false)

        var pointer = NSPoint(x: 200, y: 400)
        setPointer(pointer)
        model.hover(0)

        pointer.x += 60; setPointer(pointer)
        model.hover(1)
        XCTAssertEqual(model.previewIndex, 0, "held on the way to a right-hand card")

        pointer.x -= 60; setPointer(pointer)
        model.hover(0)
        XCTAssertEqual(model.previewIndex, 0, "moving away retargets, and 0 is the row it crossed")
    }

    /// With no card placed there is no "towards the card", and hovering behaves exactly
    /// as it always did.
    func testWithoutACardTheHoverFollowsAsBefore() {
        let (model, _, setPointer) = travellingModel(images(3), label: "no-card")

        var pointer = NSPoint(x: 600, y: 400)
        setPointer(pointer)
        model.hover(2)
        XCTAssertEqual(model.previewIndex, 2)

        pointer.x -= 60; setPointer(pointer)
        model.hover(1)
        XCTAssertEqual(model.previewIndex, 1, "no card, no hold")

        pointer.x -= 60; setPointer(pointer)
        model.hover(0)
        XCTAssertEqual(model.previewIndex, 0)
    }

    /// A vertical move is not a move towards a card on either side, so the preview
    /// follows it — the contact sheet case has to keep working.
    func testAVerticalMoveIsNotTreatedAsTravelling() {
        let (model, _, setPointer) = travellingModel(images(6), label: "vertical")
        model.setPreviewCardSide(onLeft: true)

        var pointer = NSPoint(x: 400, y: 400)
        setPointer(pointer)
        model.hover(4)

        pointer.y -= 80; setPointer(pointer)
        model.hover(1)
        XCTAssertEqual(model.previewIndex, 1, "moving down a line is not heading for the card")
    }
}
