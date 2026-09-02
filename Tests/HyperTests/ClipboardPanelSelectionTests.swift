import AppKit
import Combine
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
    /// The model holds its manager weakly, so a manager left as a local in the helper
    /// below would be gone before the first assertion — and `refresh` would return
    /// without doing anything, which is a very quiet way for a test to pass.
    private var managers: [ClipboardManager] = []

    override func tearDown() {
        managers.removeAll()
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
        managers.append(manager)
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

    /// The cap on one sheet is a drawing decision — see `ClipPanelLayout.maxGridRun` —
    /// and the keyboard must not be able to tell where the cuts fell. Thirty pictures are
    /// three sheets and one grid to walk.
    func testMovingALineWalksStraightThroughTheSeamBetweenTwoSheets() {
        let model = model(images(30), label: "sheet-seam")
        XCTAssertEqual(model.blocks.count, 3, "thirty pictures should be cut into three sheets")

        let cap = ClipPanelLayout.maxGridRun
        // The last line of the first sheet, stepping onto the first line of the second.
        model.selectedIndex = cap - ClipPanelLayout.gridColumns
        model.moveVertically(1, extending: false)
        XCTAssertEqual(model.selectedIndex, cap)

        // And back, which is the direction that would otherwise land on "the row above
        // the sheet" rather than on the line above the seam.
        model.moveVertically(-1, extending: false)
        XCTAssertEqual(model.selectedIndex, cap - ClipPanelLayout.gridColumns)
    }

    func testTheSeamIsInvisibleToLeftAndRightToo() {
        let model = model(images(30), label: "sheet-seam-lr")
        let cap = ClipPanelLayout.maxGridRun

        model.selectedIndex = cap - 1
        XCTAssertTrue(model.gridContainsSelection())
        model.move(by: 1, extending: false)
        XCTAssertEqual(model.selectedIndex, cap)
        XCTAssertTrue(model.gridContainsSelection())
    }

    /// Off the bottom of the *run*, not of the sheet: the row after all thirty.
    func testLeavingALongRunStillLandsOnTheRowAfterIt() {
        var records = images(30)
        records.append(text("在网格之后"))
        let model = model(records, label: "leave-long-run")

        model.selectedIndex = 29
        model.moveVertically(1, extending: false)
        XCTAssertEqual(model.selectedIndex, 30)
    }

    /// Which way the list scrolls the selection to. Centring on every step meant the
    /// whole list moved under the eye on every keystroke.
    func testTheScrollAnchorFollowsTheDirectionOfTravel() {
        let model = model([text("一"), text("二"), text("三")], label: "anchor")

        model.move(by: 1, extending: false)
        XCTAssertEqual(model.scrollAnchorDirection, 1)
        model.move(by: -1, extending: false)
        XCTAssertEqual(model.scrollAnchorDirection, -1)
        // An end is not a step: there is nothing just past the edge to reveal.
        model.moveToEdge(1)
        XCTAssertEqual(model.scrollAnchorDirection, 0)
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
    /// The same answers, from a dictionary rebuilt when the ticks or the list move rather
    /// than from a walk of the whole list per row asked. Every cell of a contact sheet
    /// asks, on every frame of a ⌘-drag.
    func testTheOrdinalsAreKeptAsADictionaryAndFollowTheTicks() {
        let records = images(6)
        let model = model(records, label: "ordinal-map")

        model.setChecked([records[4].id, records[1].id])
        XCTAssertEqual(model.checkedOrdinals, [records[1].id: 1, records[4].id: 2])

        model.setChecked([])
        XCTAssertTrue(model.checkedOrdinals.isEmpty)

        model.toggleSelectAll()
        XCTAssertEqual(model.checkedOrdinals.count, records.count)
        XCTAssertEqual(model.checkedOrdinal(of: records[0].id), 1)
        XCTAssertEqual(model.checkedOrdinal(of: records[5].id), 6)
    }

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

    // MARK: - The list and its arrangement cannot disagree

    /// The crash this pins: `blocks`, `groupHeaders` and `results` used to be three
    /// separate `@Published` properties, and SwiftUI ran a render between two of the
    /// writes — a contact sheet spanning rows 0…5 of a list that had just become three
    /// files long. Switching to the 文件 tab took the application out.
    ///
    /// Every state an observer can see has to be self-consistent, not just the states
    /// that happen to be final.
    func testEveryObservedListStateIndexesWithinItself() {
        var records = images(9)
        records.append(text("一段文字"))
        records.append(
            ClipRecord(
                id: UUID(), createdAt: Date(), kind: .files, preview: "/tmp/a.zip",
                digest: "selection-files", byteSize: 12,
                sourceBundleID: "com.apple.finder", sourceName: "访达", fileCount: 1
            )
        )
        let model = model(records, label: "consistency")

        var violations: [String] = []
        var seen = 0
        let token = model.$list.sink { list in
            seen += 1
            for block in list.blocks {
                if block.indices.upperBound > list.records.count {
                    violations.append(
                        "block \(block.indices) past \(list.records.count) records"
                    )
                }
            }
            for index in list.headers.keys where !list.records.indices.contains(index) {
                violations.append("header at \(index) past \(list.records.count) records")
            }
        }
        defer { token.cancel() }

        // The exact move that crashed: a list mostly made of a contact sheet, narrowed
        // to a tab holding one file.
        for next in [PanelFilter.files, .image, .text, .all, .files] {
            model.filter = next
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        XCTAssertGreaterThan(seen, 1, "the list has to have actually changed")
        XCTAssertEqual(violations, [])
    }

    /// The narrowed tab really does drop the contact sheet, rather than the invariant
    /// holding because nothing ever changed.
    func testNarrowingToATabRebuildsTheArrangement() {
        var records = images(6)
        records.append(text("一段文字"))
        let model = model(records, label: "narrow")
        XCTAssertTrue(model.blocks.contains(where: \.isGrid))
        model.filter = .text
        let deadline = Date().addingTimeInterval(0.6)
        while model.blocks.contains(where: \.isGrid), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(model.blocks.contains(where: \.isGrid))
        XCTAssertEqual(model.results.count, 1)
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
