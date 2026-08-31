import AppKit
import XCTest

@testable import Hyper

/// How the selection behaves once part of the list is a contact sheet rather than a
/// column: ↑↓ have to move a *line* of pictures, the ordered badges have to count in the
/// order a batch is actually acted on, and the rubber band has to be able to give rows
/// back as it is dragged across them again.
final class ClipboardPanelSelectionTests: XCTestCase {
    private final class SearchHarness {
        struct Request {
            let completion: (Result<ClipSearchOutcome, ClipQueryParseError>) -> Void
        }

        private(set) var requests: [Request] = []

        func execute(
            completion: @escaping (Result<ClipSearchOutcome, ClipQueryParseError>) -> Void
        ) -> ClipSearchCancellationToken? {
            requests.append(Request(completion: completion))
            return ClipSearchCancellationToken()
        }
    }

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func root(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-panel-selection-\(label)-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(url)
        return url
    }

    /// A model holding exactly the records given, with the list already laid out.
    ///
    /// Pushed through the real search path rather than assigned, so the blocks are the
    /// ones the panel would actually draw — deriving them is the thing under test.
    private func model(_ records: [ClipRecord], label: String) -> ClipboardPanelModel {
        let location = root(label)
        let store = ClipStore(root: location)
        let loaded = expectation(description: "store loaded")
        let filters = expectation(description: "smart filters loaded")
        store.whenLoaded { loaded.fulfill() }
        store.whenSmartFiltersLoaded { filters.fulfill() }
        wait(for: [loaded, filters], timeout: 5)

        let queue = PasteQueue(storeURL: location.appendingPathComponent("queue.json"))
        queue.restore()
        let manager = ClipboardManager(store: store, queue: queue)
        let harness = SearchHarness()
        let model = ClipboardPanelModel(
            manager: manager,
            searchExecutor: { _, _, completion in harness.execute(completion: completion) }
        )
        // A query is what makes the model ask its executor anything; the answer below
        // carries no terms, so the list is grouped and laid out exactly as an unsearched
        // one is.
        model.query = "种子"
        let deadline = Date().addingTimeInterval(2)
        while harness.requests.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        harness.requests.last?.completion(
            .success(ClipSearchOutcome(records: records, terms: [], contexts: [:]))
        )
        let settled = Date().addingTimeInterval(2)
        while model.results.count != records.count, Date() < settled {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return model
    }

    /// All from the same instant, so every row lands in one band and no header splits
    /// the run of pictures under test.
    private func images(_ count: Int) -> [ClipRecord] {
        let now = Date()
        return (0..<count).map { index in
            let id = UUID()
            return ClipRecord(
                id: id, createdAt: now, kind: .image, preview: "图片 \(index)",
                digest: "selection-\(id.uuidString)", byteSize: 1024,
                sourceBundleID: "com.example.shot", sourceName: "Shot",
                hasThumbnail: true, pixelWidth: 800, pixelHeight: 600
            )
        }
    }

    private func text(_ body: String) -> ClipRecord {
        let id = UUID()
        return ClipRecord(
            id: id, createdAt: Date(), kind: .text, preview: body,
            digest: "selection-\(id.uuidString)", byteSize: body.utf8.count,
            sourceBundleID: "com.example.editor", sourceName: "Editor"
        )
    }

    // MARK: - Moving inside a contact sheet

    func testDownMovesAWholeLineInsideAContactSheet() {
        let model = model(images(9), label: "line-down")
        XCTAssertEqual(model.blocks, [.grid(0..<9)])

        model.selectedIndex = 0
        model.moveVertically(1, extending: false)
        XCTAssertEqual(model.selectedIndex, ClipPanelLayout.gridColumns)

        model.moveVertically(-1, extending: false)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    /// Off the bottom line of a sheet is the row *after* the sheet, not three rows past
    /// the end of the list.
    func testMovingPastTheLastLineLeavesTheSheetForTheNextRow() {
        var records = images(4)
        records.append(text("之后的一行"))
        let model = model(records, label: "leave-sheet")
        XCTAssertEqual(model.blocks, [.grid(0..<4), .row(4)])

        model.selectedIndex = 3
        model.moveVertically(1, extending: false)
        XCTAssertEqual(model.selectedIndex, 4, "the row after the sheet")
    }

    func testMovingUpOutOfASheetLandsOnTheRowAboveIt() {
        var records = [text("之前的一行")]
        records += images(4)
        let model = model(records, label: "enter-sheet")
        XCTAssertEqual(model.blocks, [.row(0), .grid(1..<5)])

        model.selectedIndex = 1
        model.moveVertically(-1, extending: false)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    /// Outside a sheet the key means exactly what it always meant.
    func testDownMovesOneRowOutsideASheet() {
        let model = model([text("一"), text("二"), text("三")], label: "plain-rows")
        XCTAssertEqual(model.blocks, [.row(0), .row(1), .row(2)])

        model.selectedIndex = 0
        model.moveVertically(1, extending: false)
        XCTAssertEqual(model.selectedIndex, 1)
    }

    func testArrowsOnlyBelongToTheGridWhileTheSelectionIsInsideOne() {
        var records = [text("在网格之前")]
        records += images(4)
        let model = model(records, label: "grid-claim")

        model.selectedIndex = 0
        XCTAssertFalse(model.gridContainsSelection(), "← → still open and close the preview")
        model.selectedIndex = 2
        XCTAssertTrue(model.gridContainsSelection())
    }

    func testMovingALineKeepsTicketingEveryRowItPassedWhenExtending() {
        let model = model(images(9), label: "extend")
        model.selectedIndex = 0
        model.moveVertically(1, extending: true)

        XCTAssertEqual(model.checked.count, ClipPanelLayout.gridColumns + 1)
    }

    // MARK: - Ordered selection

    /// The badges count in list order because that is the order `actionTargets` merges
    /// in. Numbering them by when they were clicked would promise a sequence the paste
    /// does not honour.
    func testBadgesCountInListOrderNotInTheOrderTheyWereSelected() {
        let records = images(6)
        let model = model(records, label: "ordinals")

        model.setChecked([records[4].id, records[1].id, records[3].id])

        XCTAssertEqual(model.checkedOrdinal(of: records[1].id), 1)
        XCTAssertEqual(model.checkedOrdinal(of: records[3].id), 2)
        XCTAssertEqual(model.checkedOrdinal(of: records[4].id), 3)
        XCTAssertNil(model.checkedOrdinal(of: records[0].id))
        XCTAssertEqual(
            model.actionTargets.map(\.id), [records[1].id, records[3].id, records[4].id]
        )
    }

    /// A rubber band is live: dragging it back over a picture has to *unselect* it, which
    /// a set that only ever grew could not do.
    func testTheRubberBandReplacesTheSelectionRatherThanAddingToIt() {
        let records = images(6)
        let model = model(records, label: "marquee")

        model.setChecked([records[0].id, records[1].id, records[2].id])
        XCTAssertEqual(model.checked.count, 3)

        model.setChecked([records[0].id])
        XCTAssertEqual(model.checked, [records[0].id])

        model.setChecked([])
        XCTAssertTrue(model.checked.isEmpty)
    }

    // MARK: - Appearance

    func testTheFaceButtonAlwaysChangesWhatIsOnScreenAndIsPersisted() {
        let model = model([text("一")], label: "appearance")
        var written: [ClipPanelAppearance] = []
        model.persistAppearance = { written.append($0) }

        model.applyAppearance(.system, systemIsDark: true)
        XCTAssertTrue(model.theme.dark)

        model.toggleAppearance()
        XCTAssertFalse(model.theme.dark, "one press has to visibly change the panel")
        XCTAssertEqual(written, [.light])

        model.toggleAppearance()
        XCTAssertTrue(model.theme.dark)
        XCTAssertEqual(written, [.light, .dark])
    }

    func testAStoredFaceOverridesWhatTheSystemIsDoing() {
        let model = model([text("一")], label: "override")

        model.applyAppearance(.dark, systemIsDark: false)
        XCTAssertTrue(model.theme.dark)

        model.applyAppearance(.light, systemIsDark: true)
        XCTAssertFalse(model.theme.dark)
    }

    // MARK: - Toast

    func testTheToastReplacesItselfRatherThanQueueing() {
        let model = model([text("一")], label: "toast")

        model.flash("已粘贴 → A")
        XCTAssertEqual(model.toast, "已粘贴 → A")
        model.flash("已粘贴 → B")
        XCTAssertEqual(model.toast, "已粘贴 → B", "the second is the one worth reading")

        model.clearToast()
        XCTAssertNil(model.toast)
    }
}
