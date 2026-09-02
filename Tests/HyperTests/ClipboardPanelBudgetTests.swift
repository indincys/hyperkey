import AppKit
import Combine
import SwiftUI
import XCTest

@testable import Hyper

/// What the panel costs to keep on screen, counted rather than looked at.
///
/// Every one of these is a budget: how many times one action may invalidate the panel,
/// how many times one hover may read a file off disk. They are the assertions that stop
/// the panel becoming slow again by degrees — a published property added in the obvious
/// place, a value derived in a `body` because that is where it is read.
final class ClipboardPanelBudgetTests: XCTestCase {
    private var roots: [URL] = []
    /// The model holds its manager weakly; a local would be gone before the first
    /// assertion and every `refresh` would quietly do nothing.
    private var managers: [ClipboardManager] = []
    private var tokens: Set<AnyCancellable> = []

    override func tearDown() {
        tokens.removeAll()
        managers.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    private final class SearchHarness {
        var completions: [(Result<ClipSearchOutcome, ClipQueryParseError>) -> Void] = []

        func execute(
            completion: @escaping (Result<ClipSearchOutcome, ClipQueryParseError>) -> Void
        ) -> ClipSearchCancellationToken? {
            completions.append(completion)
            return ClipSearchCancellationToken()
        }
    }

    private func root(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-panel-budget-\(label)-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(url)
        return url
    }

    private func manager(_ label: String) -> ClipboardManager {
        let location = root(label)
        let store = ClipStore(root: location)
        let loaded = expectation(description: "store loaded")
        let filters = expectation(description: "smart filters loaded")
        store.whenLoaded { loaded.fulfill() }
        store.whenSmartFiltersLoaded { filters.fulfill() }
        wait(for: [loaded, filters], timeout: 10)
        let queue = PasteQueue(storeURL: location.appendingPathComponent("queue.json"))
        queue.restore()
        let manager = ClipboardManager(store: store, queue: queue)
        managers.append(manager)
        return manager
    }

    /// A model with a list already in it, pushed through the real search path so the
    /// bands and the arrangement are the ones the panel would draw.
    private func model(
        _ records: [ClipRecord], label: String, previewCache: ClipPreviewCache? = nil
    ) -> ClipboardPanelModel {
        let harness = SearchHarness()
        let model = ClipboardPanelModel(
            manager: manager(label),
            previewCache: previewCache,
            searchExecutor: { _, _, completion in harness.execute(completion: completion) }
        )
        model.query = "种子"
        spin(until: { !harness.completions.isEmpty }, timeout: 3)
        harness.completions.removeLast()(
            .success(ClipSearchOutcome(records: records, terms: [], contexts: [:]))
        )
        spin(until: { model.results.count == records.count }, timeout: 3)
        return model
    }

    /// A model whose list comes out of a real store, and which is actually on screen.
    ///
    /// The harness above seeds through the search executor, which `panelWillShow` then
    /// throws away — it re-runs the search with an empty query, and an empty query is
    /// answered synchronously from the store. Anything that has to be true *while the
    /// panel is up* therefore has to be seeded into the store itself.
    private func visibleModel(
        images count: Int, label: String, previewCache: ClipPreviewCache
    ) -> ClipboardPanelModel {
        let manager = manager(label)
        for index in 0..<count {
            let payload: ClipPayload = [
                [NSPasteboard.PasteboardType.png.rawValue: Data("图片 \(index)".utf8)]
            ]
            _ = manager.store.insert(
                ClipStore.Insertion(
                    payload: payload, kind: .image, oversized: false,
                    byteSize: ClipPayloadCoder.byteSize(payload),
                    sourceBundleID: "com.example.shot", sourceName: "Shot"
                )
            )
        }
        manager.store.waitForPendingWrites()
        let model = ClipboardPanelModel(manager: manager, previewCache: previewCache)
        model.panelWillShow()
        spin(until: { model.results.count == count }, timeout: 5)
        return model
    }

    private func spin(until predicate: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func counting(_ model: ClipboardPanelModel) -> () -> Int {
        var count = 0
        model.objectWillChange.sink { count += 1 }.store(in: &tokens)
        return { count }
    }

    private func text(_ body: String, at date: Date = Date()) -> ClipRecord {
        let id = UUID()
        return ClipRecord(
            id: id, createdAt: date, kind: .text, preview: body,
            digest: "budget-\(id.uuidString)", byteSize: body.utf8.count,
            sourceBundleID: "com.example.editor", sourceName: "Editor"
        )
    }

    private func image(_ index: Int) -> ClipRecord {
        let id = UUID()
        return ClipRecord(
            id: id, createdAt: Date(), kind: .image, preview: "图片 \(index)",
            digest: "budget-image-\(id.uuidString)", byteSize: 4096,
            sourceBundleID: "com.example.shot", sourceName: "Shot",
            hasThumbnail: true, pixelWidth: 800, pixelHeight: 600
        )
    }

    // MARK: - One search answer, one invalidation

    /// `apply` used to write seven published properties one after another: the list, the
    /// pill counts, the terms, the contexts, the explanations, the ticks and the
    /// selection. Each of those was a full invalidation of the panel *and* a
    /// re-derivation of the preview window's frame — seven of each, for one answer.
    func testOneSearchAnswerCostsAtMostTwoPublishedChanges() {
        let model = model([text("一"), text("二"), text("三")], label: "apply-budget")
        let replacement = [text("四"), text("五")]
        let publishes = counting(model)

        model.apply(
            ClipSearchOutcome(records: replacement, terms: ["四"], contexts: [:]),
            resettingSelection: true
        )

        XCTAssertEqual(model.results.map(\.id), replacement.map(\.id))
        XCTAssertEqual(model.highlightTerms, ["四"])
        XCTAssertEqual(model.filterCounts[.all], 2)
        XCTAssertLessThanOrEqual(
            publishes(), 2, "one answer must not invalidate the panel more than twice"
        )
    }

    /// And an answer that changes nothing at all costs nothing at all — which is the
    /// common case, because every copy made anywhere on the machine reaches here.
    func testAnAnswerThatChangesNothingPublishesNothing() {
        let records = [text("一"), text("二")]
        let model = model(records, label: "apply-idempotent")
        let publishes = counting(model)

        model.apply(
            ClipSearchOutcome(records: records, terms: [], contexts: [:]),
            resettingSelection: false
        )

        XCTAssertEqual(publishes(), 0)
    }

    // MARK: - The thirty-second clock

    /// A tick that crosses no band boundary changes nothing the list draws: the rows
    /// stopped showing times in 1.4.0, and which band a row is in changes at midnight.
    func testATickThatCrossesNoBoundaryLeavesTheListAlone() {
        let model = model([text("一"), text("二")], label: "clock-quiet")
        let noon = Self.noon()
        model.clockSource = { noon }
        model.startClock()
        defer { model.stopClock() }

        let before = model.list
        let publishes = counting(model)
        model.clockSource = { noon.addingTimeInterval(30) }
        model.tickClock()

        XCTAssertEqual(model.list, before, "the list was rebuilt for a clock that had not moved")
        XCTAssertEqual(publishes(), 0, "thirty seconds must not invalidate the panel")
        XCTAssertEqual(
            model.previewClock.now, noon.addingTimeInterval(30),
            "the card's own clock still moves — it is the only thing that shows a time"
        )
    }

    /// Midnight is what the reading is actually for.
    func testATickThatCrossesMidnightRebuildsTheBands() {
        let noon = Self.noon()
        let model = model([text("今天的一条", at: noon)], label: "clock-midnight")
        model.clockSource = { noon }
        model.startClock()
        defer { model.stopClock() }
        XCTAssertEqual(model.groupHeaders[0], "今天")

        model.clockSource = { noon.addingTimeInterval(24 * 3600) }
        model.tickClock()

        XCTAssertEqual(model.clockTick, noon.addingTimeInterval(24 * 3600))
        XCTAssertEqual(model.groupHeaders[0], "昨天", "the row moved band and the header did not")
    }

    func testTheBoundaryTestItselfKnowsWhatItIsLookingAt() {
        let noon = Self.noon()
        XCTAssertFalse(
            ClipboardPanelModel.groupingBoundaryCrossed(
                from: noon, to: noon.addingTimeInterval(30)
            )
        )
        XCTAssertTrue(
            ClipboardPanelModel.groupingBoundaryCrossed(
                from: noon, to: noon.addingTimeInterval(24 * 3600)
            )
        )
    }

    private static func noon() -> Date {
        let calendar = Calendar.current
        return calendar.date(
            bySettingHour: 12, minute: 0, second: 0, of: calendar.startOfDay(for: Date())
        ) ?? Date()
    }

    // MARK: - Thumbnails landing together

    /// A screenful of pictures used to write a published dictionary once per decode:
    /// twenty-odd full invalidations of the panel in the fraction of a second it takes
    /// them all to arrive.
    func testAScreenfulOfThumbnailsCommitsInOnePass() {
        let loaded = ReadCounter()
        let cache = ClipPreviewCache { request in
            loaded.record(request.record.id)
            return .success(ClipPreviewAsset(image: nil, files: [], overflowFileCount: 0), cost: 1)
        }
        let model = visibleModel(images: 10, label: "thumbnails", previewCache: cache)
        defer { model.panelDidHide() }
        for record in model.results { model.visualDidAppear(record) }

        // Deliberately *not* running the run loop while the workers decode: every
        // completion they post queues up behind this thread, so they all land in the one
        // turn below — which is exactly the case being budgeted, ten decodes finishing
        // together costing one commit rather than ten. Polling the loader rather than
        // sleeping a fixed time, so a loaded machine makes the test slower, never flaky.
        let deadline = Date().addingTimeInterval(10)
        while loaded.total < model.results.count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(loaded.total, 10, "the decodes never finished")

        // Counted from here: the completions are queued behind this thread and have not
        // run yet, so what follows is the batch and nothing else.
        let publishes = counting(model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        for record in model.results {
            if case .idle = model.visualState(for: record) {
                XCTFail("a thumbnail never left its idle state")
            }
        }
        XCTAssertLessThanOrEqual(
            publishes(), 2,
            "ten thumbnails landing together cost \(publishes()) invalidations"
        )
    }

    // MARK: - The preview's own reads

    /// The pointer moving between two rows is how anyone compares two entries, and every
    /// crossing used to be a fresh authenticated read and plist decode of a file that had
    /// just been read.
    func testGoingBackToAPreviewedRowDoesNotReadItAgain() async {
        let first = text("第一条")
        let second = text("第二条")
        let model = model([first, second], label: "preview-lru")

        let reads = ReadCounter()
        model.previewPayloadReader = { id in
            reads.record(id)
            return nil
        }

        _ = await model.previewPayload(for: first)
        _ = await model.previewPayload(for: second)
        _ = await model.previewPayload(for: first)

        XCTAssertEqual(reads.total, 2, "the second visit to a row must come out of the cache")
        XCTAssertEqual(reads.count(first.id), 1)
        XCTAssertEqual(reads.count(second.id), 1)
    }

    /// The cache is keyed by what the bytes on disk actually depend on: the entry and its
    /// digest.
    ///
    /// It was keyed by the store's *generation*, which moves on every history mutation —
    /// so a copy made anywhere on the machine emptied the whole cache, while the panel
    /// was open and being read. Nothing but a rewrite of this entry may evict it, and a
    /// rewrite must.
    func testThePreviewCacheIsKeyedByTheEntryRatherThanTheHistory() async {
        let record = text("第一条")
        let model = model([record], label: "preview-key")
        let reads = ReadCounter()
        model.previewPayloadReader = { id in
            reads.record(id)
            return nil
        }

        _ = await model.previewPayload(for: record)
        _ = await model.previewPayload(for: record)
        XCTAssertEqual(reads.total, 1, "the same entry, unchanged, is read once")

        // The same row, rewritten in the editor: same id, new digest, new bytes.
        var edited = record
        edited.digest = record.digest + "-edited"
        _ = await model.previewPayload(for: edited)
        XCTAssertEqual(reads.total, 2, "a rewritten entry has to be read again")
    }

    /// Eight rows deep, because the cache is eight entries; the ninth pushes the first
    /// out, and going back to it reads again.
    func testTheCacheIsBoundedAndEvictsTheLeastRecentlyUsed() async {
        let records = (0..<9).map { text("第 \($0) 条") }
        let model = model(records, label: "preview-lru-evict")
        let reads = ReadCounter()
        model.previewPayloadReader = { id in
            reads.record(id)
            return nil
        }

        for record in records { _ = await model.previewPayload(for: record) }
        _ = await model.previewPayload(for: records[0])

        XCTAssertEqual(reads.count(records[0].id), 2, "the oldest entry should have been evicted")
        XCTAssertEqual(reads.count(records[8].id), 1)
    }

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [UUID: Int] = [:]

        /// Called on the preview worker, never on the main thread.
        func record(_ id: UUID) {
            lock.lock()
            counts[id, default: 0] += 1
            lock.unlock()
        }

        func count(_ id: UUID) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[id] ?? 0
        }

        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }
    }

    // MARK: - The rubber band, through the model

    /// The same seam as `ClipMarqueeResolver`'s own tests, but through the object the
    /// sheets actually register with and the selection they actually set.
    func testABandAcrossTwoRegisteredSheetsChecksRowsInBoth() {
        let records = (0..<18).map { image($0) }
        let model = model(records, label: "marquee-model")
        XCTAssertEqual(model.blocks.count, 2, "eighteen pictures are two sheets")

        let width: CGFloat = 356
        let topMetrics = ImageGridMetrics(width: width, count: 12)
        let bottomMetrics = ImageGridMetrics(width: width, count: 6)
        model.registerSheet(
            ClipSheetRegistration(
                range: 0..<12,
                frame: CGRect(x: 0, y: 0, width: width, height: topMetrics.totalHeight),
                metrics: topMetrics
            )
        )
        model.registerSheet(
            ClipSheetRegistration(
                range: 12..<18,
                frame: CGRect(
                    x: 0, y: topMetrics.totalHeight + 6,
                    width: width, height: bottomMetrics.totalHeight
                ),
                metrics: bottomMetrics
            )
        )

        // Started on the last line of the first sheet and dragged into the second.
        // Measured from the metrics' own line origins rather than from cell heights: the
        // lines are separated by a gap, and a band that started a gap early would take
        // the line above as well and quietly make this assertion about something else.
        let top = topMetrics.origin(of: 9).y + 2
        model.applyMarquee(
            CGRect(
                x: 0, y: top,
                width: width,
                height: (topMetrics.totalHeight - top) + 6 + bottomMetrics.cellHeight - 2
            )
        )

        XCTAssertTrue(model.checked.contains(records[9].id), "the far side of the seam")
        XCTAssertTrue(model.checked.contains(records[12].id))
        XCTAssertEqual(model.checkedOrdinal(of: records[9].id), 1)
        XCTAssertEqual(model.checkedOrdinal(of: records[12].id), 4)
    }

    /// A sheet that has scrolled away is not somewhere a band can reach.
    func testASheetThatHasGoneStopsAnsweringTheBand() {
        let records = (0..<18).map { image($0) }
        let model = model(records, label: "marquee-unregister")
        let metrics = ImageGridMetrics(width: 356, count: 12)
        model.registerSheet(
            ClipSheetRegistration(
                range: 0..<12,
                frame: CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight),
                metrics: metrics
            )
        )
        model.applyMarquee(CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight))
        XCTAssertEqual(model.checked.count, 12)

        model.unregisterSheet(0..<12)
        model.applyMarquee(CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight))
        XCTAssertTrue(model.checked.isEmpty)
    }

    /// Two sheets can share a first row, and SwiftUI does not retire the old one first.
    ///
    /// Deleting a picture inside a long run shortens the block below it from `12..<17`
    /// to `12..<16`. If the row at 12 is replaced as well, the block gets a new identity
    /// and SwiftUI runs the arriving view's `onAppear` *before* the departing view's
    /// `onDisappear` — so an unregister keyed on the first row alone deletes the
    /// registration that has just been made, and a sheet in plain sight stops answering
    /// the band.
    func testALateDisappearanceDoesNotTakeAwayTheSheetThatReplacedIt() {
        let model = model((0..<16).map { image($0) }, label: "marquee-identity")
        XCTAssertEqual(model.blocks.map(\.indices), [0..<12, 12..<16])
        let metrics = ImageGridMetrics(width: 356, count: 4)
        model.registerSheet(
            ClipSheetRegistration(
                range: 12..<16,
                frame: CGRect(x: 0, y: 400, width: 356, height: metrics.totalHeight),
                metrics: metrics
            )
        )

        // The view that used to hold 12..<17, going away late.
        model.unregisterSheet(12..<17)
        XCTAssertEqual(
            model.sheetRegistrations.map(\.range), [12..<16],
            "the sheet that is actually on screen was thrown away"
        )

        // And the sheet's own disappearance still takes it out.
        model.unregisterSheet(12..<16)
        XCTAssertTrue(model.sheetRegistrations.isEmpty)
    }

    /// Hiding the panel orders a window out; it does not tear the view tree down. No
    /// sheet runs `onAppear` again on the way back, so anything forgotten here is
    /// forgotten until the panel is rebuilt.
    func testHidingThePanelDoesNotForgetTheSheetsStillLaidOut() {
        let records = (0..<18).map { image($0) }
        let model = model(records, label: "marquee-hide")
        let metrics = ImageGridMetrics(width: 356, count: 12)
        model.registerSheet(
            ClipSheetRegistration(
                range: 0..<12,
                frame: CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight),
                metrics: metrics
            )
        )

        model.panelDidHide()

        XCTAssertEqual(model.sheetRegistrations.map(\.range), [0..<12])
        model.applyMarquee(CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight))
        XCTAssertEqual(model.checked.count, 12, "the band found nothing to select")
    }

    /// A registration describes a layout, and the list can be rebuilt underneath one —
    /// a copy made in another application while the panel is open renumbers every block
    /// below it. A rectangle mapped to rows that have since moved is worse than no
    /// rectangle at all.
    func testARegistrationThatNoLongerMatchesABlockIsIgnored() {
        let model = model((0..<18).map { image($0) }, label: "marquee-stale")
        let metrics = ImageGridMetrics(width: 356, count: 12)
        model.registerSheet(
            ClipSheetRegistration(
                range: 0..<12,
                frame: CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight),
                metrics: metrics
            )
        )
        // A shape the list does not have: the same rows, cut differently.
        model.registerSheet(
            ClipSheetRegistration(
                range: 3..<9,
                frame: CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight),
                metrics: ImageGridMetrics(width: 356, count: 6)
            )
        )

        XCTAssertEqual(model.sheetRegistrations.map(\.range), [0..<12])
    }

    // MARK: - Dragging across the list

    /// The list and every row in it is a drop target, so a file dragged from the top of
    /// the panel to the bottom crosses twenty of them.
    func testCrossingRowsWithADragOnlyRaisesTheBorderOnce() {
        let model = model([text("一"), text("二")], label: "drop-border")
        let publishes = counting(model)

        model.dropTargetEntered()
        model.dropTargetEntered()
        model.dropTargetEntered()

        XCTAssertTrue(model.dropTargeted)
        XCTAssertEqual(publishes(), 1, "only the first crossing changes anything")
    }

    // MARK: - Accessibility

    /// The toast is drawn for the eye and hidden from the accessibility tree — it is a
    /// caption on something that has already happened. Said out loud instead.
    func testTheToastIsAnnouncedRatherThanLeftToBeFound() {
        let model = model([text("一")], label: "announce")
        var spoken: [String] = []
        model.announce = { spoken.append($0) }

        model.flash("已粘贴 → 备忘录")

        XCTAssertEqual(spoken, ["已粘贴 → 备忘录"])
        XCTAssertEqual(model.toast, "已粘贴 → 备忘录")
    }

    /// A search that silently stops matching anything is the worst way to find out a
    /// query is malformed, and the red line under the field is not something a VoiceOver
    /// user is going to look at.
    func testASyntaxErrorIsAnnouncedWhenItAppears() {
        let model = model([text("一")], label: "announce-query")
        var spoken: [String] = []
        model.announce = { spoken.append($0) }

        model.query = #"app:"unterminated"#

        XCTAssertNotNil(model.queryIssue)
        XCTAssertEqual(spoken.count, 1)
        XCTAssertTrue(spoken.first?.contains("搜索语法错误") == true)
    }

    /// Once, as it appears — not once per keystroke.
    ///
    /// Every further character inside a malformed query moves the reported position,
    /// which is a different value; announcing each of those would talk over the person
    /// typing, which is how a screen reader stops being usable.
    func testAStandingSyntaxErrorIsNotAnnouncedAgainOnEveryKeystroke() {
        let model = model([text("一")], label: "announce-repeat")
        var spoken: [String] = []
        model.announce = { spoken.append($0) }

        model.query = #"app:"unterminated"#
        model.query = #"app:"unterminated s"#
        model.query = #"app:"unterminated se"#
        XCTAssertEqual(spoken.count, 1, "the error was announced \(spoken.count) times")

        // Fixed, then broken again: that is a new error and does get said.
        model.query = "plain"
        spin(until: { model.queryIssue == nil }, timeout: 1)
        model.query = #"app:"broken again"#
        XCTAssertEqual(spoken.count, 2)
    }

    // MARK: - VoiceOver

    /// A row's age is the one derived value with a clock in it, so it is only computed
    /// when something will actually read it. Which means turning VoiceOver on has to be
    /// noticed — ⌘F5 is a key on the keyboard, pressed while looking at something.
    func testTurningVoiceOverOnGivesEveryRowItsAgeBack() {
        let model = model([text("一"), text("二")], label: "voiceover")
        for record in model.results {
            XCTAssertNil(
                model.presentation(for: record).spokenTime,
                "with VoiceOver off the age is not worth computing"
            )
        }

        model.setVoiceOverEnabled(true)

        for record in model.results {
            XCTAssertNotNil(
                model.presentation(for: record).spokenTime,
                "a row VoiceOver is about to read has to know how old it is"
            )
        }
    }

    /// And it stays current, which is what the thirty-second clock is for — the reuse
    /// path has to refresh the age rather than being skipped or rebuilt wholesale.
    func testWithVoiceOverOnTheAgesFollowTheClockAndNothingElseIsRebuilt() {
        let noon = Self.noon()
        let record = text("一", at: noon)
        let model = model([record], label: "voiceover-clock")
        model.clockSource = { noon }
        model.startClock()
        defer { model.stopClock() }
        model.setVoiceOverEnabled(true)

        let before = model.presentation(for: record)
        XCTAssertEqual(before.spokenTime, "刚刚")

        model.clockSource = { noon.addingTimeInterval(3600) }
        model.tickClock()

        let after = model.presentation(for: record)
        XCTAssertEqual(after.spokenTime, "1 小时前")
        // Everything else is the reused value, not a fresh derivation.
        XCTAssertEqual(after.displayTitle, before.displayTitle)
        XCTAssertEqual(after.spokenPrefix, before.spokenPrefix)
        XCTAssertEqual(after.digest, before.digest)
    }

    // MARK: - Focus

    /// The window is built once and reused, so the header's `onAppear` runs once in a
    /// session — and every appearance after the first could open with the keyboard
    /// somewhere else entirely.
    func testEveryAppearanceAsksForTheSearchFieldAgain() {
        let model = model([text("一")], label: "focus")
        let before = model.searchFocusTick

        model.panelWillShow()
        let afterFirst = model.searchFocusTick
        XCTAssertGreaterThan(afterFirst, before)

        model.panelDidHide()
        model.panelWillShow()
        XCTAssertGreaterThan(model.searchFocusTick, afterFirst)

        model.panelDidHide()
    }

    // MARK: - Prewarming

    /// Laying the panel out is what prewarming is *for*, and laying a row out runs its
    /// `onAppear` — which is where thumbnails are asked for. Decoding pictures for a
    /// window nobody is looking at is disk I/O and image decode spent on nothing, and on
    /// the stale list at that, since `panelWillShow` has not run.
    func testNothingIsDecodedWhileThePanelIsOffScreen() {
        let loaded = ReadCounter()
        let cache = ClipPreviewCache { request in
            loaded.record(request.record.id)
            return .success(ClipPreviewAsset(image: nil, files: [], overflowFileCount: 0), cost: 1)
        }
        // Fourteen, so the last of them is outside the window `updateVisualPrefetch`
        // covers: what is being tested is the *resume*, not the prefetch that would have
        // reached the top of the list anyway.
        let model = visibleModel(images: 14, label: "prewarm-decode", previewCache: cache)
        defer { model.panelDidHide() }
        // Back off screen, and let the prefetching that a real appearance does drain, so
        // what is counted below is only what the *hidden* panel asked for.
        model.panelDidHide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let baseline = loaded.total
        let far = model.results[13]
        XCTAssertEqual(
            loaded.count(far.id), 0, "row 13 is outside the prefetch window, by design"
        )

        // What a prewarm's layout does: rows appear, with the panel not on screen.
        for record in model.results { model.visualDidAppear(record) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(
            loaded.total, baseline,
            "a hidden panel asked for \(loaded.total - baseline) decodes"
        )
        for record in model.results {
            guard case .idle = model.visualState(for: record) else {
                return XCTFail("a hidden panel started a thumbnail")
            }
        }

        // And the appearance the layout was preparing for picks them up, even though
        // `onAppear` does not run a second time for rows that never went away.
        model.panelWillShow()
        let deadline = Date().addingTimeInterval(5)
        while loaded.count(far.id) == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(
            loaded.count(far.id), 0, "a row laid out early never got its picture"
        )
    }

    /// The second `Hyper+Space` of a session, which is every use of the panel but one.
    ///
    /// Hiding the panel does not destroy the view tree, so no row's `onAppear` runs
    /// again when it comes back: the model's own record of what is laid out is the only
    /// thing that still knows row 13 is on screen. Emptying that record on the way down
    /// left everything outside `updateVisualPrefetch`'s window — index-6…index+10 — as
    /// permanent placeholders from the second appearance onwards.
    func testThumbnailsComeBackWhenThePanelIsShownAgain() {
        let loaded = ReadCounter()
        let cache = ClipPreviewCache { request in
            loaded.record(request.record.id)
            return .success(ClipPreviewAsset(image: nil, files: [], overflowFileCount: 0), cost: 1)
        }
        // Fourteen again, so row 13 is past the prefetch window and can only be reached
        // by the resume.
        let model = visibleModel(images: 14, label: "second-show", previewCache: cache)
        defer { model.panelDidHide() }
        for record in model.results { model.visualDidAppear(record) }
        let far = model.results[13]
        spin(until: { loaded.count(far.id) > 0 }, timeout: 5)
        XCTAssertGreaterThan(loaded.count(far.id), 0, "the first appearance never drew it")

        model.panelDidHide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let baseline = loaded.count(far.id)

        model.panelWillShow()
        spin(until: { loaded.count(far.id) > baseline }, timeout: 5)
        XCTAssertGreaterThan(
            loaded.count(far.id), baseline,
            "row 13 came back to a panel that had forgotten it was on screen"
        )
    }

    /// Building the window is the whole of what the first `Hyper+Space` of a session
    /// pays for. Doing it early must not show anything, and must be safe to ask for
    /// more than once.
    func testPrewarmingBuildsTheWindowWithoutShowingIt() {
        let controller = ClipboardPanelController(manager: manager("prewarm"))

        controller.prewarm()
        XCTAssertFalse(controller.isVisible, "prewarming must not put a panel on screen")

        controller.prewarm()
        controller.prewarm()
        XCTAssertFalse(controller.isVisible)

        // And the ordinary path still works over the top of it.
        controller.show()
        XCTAssertTrue(controller.isVisible)
        controller.hide(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}
