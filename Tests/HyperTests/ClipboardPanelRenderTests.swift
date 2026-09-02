import AppKit
import SwiftUI
import XCTest

@testable import Hyper

/// Drives the real SwiftUI panel through a hosting view.
///
/// The crash this exists for did not happen in the model — every value there was
/// individually fine. It happened inside `ForEach`, because SwiftUI rendered between two
/// of the model's published writes and drew a contact sheet spanning rows 0…5 of a list
/// that had just become three files long. Nothing short of actually laying the view out
/// would have caught it, so that is what this does.
final class ClipboardPanelRenderTests: XCTestCase {
    private var roots: [URL] = []
    /// The model holds its manager weakly; a local would be gone before the first
    /// layout, and `refresh` would quietly do nothing.
    private var managers: [ClipboardManager] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil }
        windows.removeAll()
        managers.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private final class Harness {
        var completions: [(Result<ClipSearchOutcome, ClipQueryParseError>) -> Void] = []
    }

    /// The exact move that took the application out: a list mostly made of a contact
    /// sheet, narrowed to a tab holding one row, with the view on screen throughout.
    func testSwitchingTabsUnderAContactSheetDoesNotCrash() {
        let model = seededModel(label: "tabs")
        let window = host(ClipboardPanelView(model: model, actions: Self.inertActions()))

        for next in [PanelFilter.files, .image, .text, .url, .pinned, .all, .files] {
            model.filter = next
            settle(window)
        }

        XCTAssertEqual(model.filter, .files)
        for block in model.blocks {
            XCTAssertLessThanOrEqual(block.indices.upperBound, model.results.count)
        }
    }

    /// The same hazard from the other direction: the history itself changing under a
    /// sheet, which is what a copy made in another application while the panel is up does.
    func testTheListShrinkingUnderAContactSheetDoesNotCrash() {
        let model = seededModel(label: "shrink")
        let window = host(ClipboardPanelView(model: model, actions: Self.inertActions()))
        XCTAssertTrue(model.blocks.contains(where: \.isGrid))

        model.filter = .image
        settle(window)
        model.filter = .all
        settle(window)
        model.query = "没有这个东西"
        settle(window, seconds: 0.5)

        XCTAssertLessThanOrEqual(model.blocks.count, model.results.count + 1)
    }

    /// Both faces, and both of the accessibility settings that change one.
    ///
    /// The palette is a value the whole panel is drawn from, and four of its colours now
    /// have three possible values each. Laying the real panel out in each combination is
    /// the cheapest way to be sure none of them is a colour SwiftUI cannot resolve or a
    /// border width that breaks a layout — and it is a combination nobody looks at while
    /// developing, because a developer's Mac is on one of them.
    func testThePanelLaysOutInEveryFaceItCanWear() {
        let model = seededModel(label: "faces")
        let window = host(ClipboardPanelView(model: model, actions: Self.inertActions()))

        for dark in [true, false] {
            for reduceTransparency in [false, true] {
                for increaseContrast in [false, true] {
                    model.applyAppearance(
                        dark ? .dark : .light, systemIsDark: dark,
                        reduceTransparency: reduceTransparency,
                        increaseContrast: increaseContrast
                    )
                    settle(window, seconds: 0.05)
                    XCTAssertEqual(model.theme.dark, dark)
                    XCTAssertEqual(model.theme.opaque, reduceTransparency)
                    XCTAssertEqual(model.theme.borderWidth, increaseContrast ? 2 : 1)
                }
            }
        }
        XCTAssertFalse(model.results.isEmpty, "the list has to have been drawn throughout")
    }

    /// A long run of pictures is several sheets, and a rubber band dragged across them is
    /// resolved in the list's own coordinate space — so the sheets have to *report*
    /// themselves in it, correctly, from a real layout.
    ///
    /// No pure test can check this: the arithmetic is right in isolation and still wrong
    /// if the space is upside down or measured from the wrong view. Hosting the panel is
    /// the only way to find that out.
    func testEverySheetOnScreenRegistersItselfInListCoordinates() {
        let model = seededModel(label: "sheets", records: Self.pictures(count: 18))
        let window = host(ClipboardPanelView(model: model, actions: Self.inertActions()))
        settle(window, seconds: 0.4)

        XCTAssertEqual(model.blocks.count, 2, "eighteen pictures should be two sheets")
        let sheets = model.sheetRegistrations
        XCTAssertEqual(sheets.count, 2, "both sheets have to have registered")
        XCTAssertEqual(sheets.map(\.range), model.blocks.map(\.indices))

        // y downwards, which is what the marquee view measures its band in.
        XCTAssertGreaterThan(sheets[1].frame.minY, sheets[0].frame.minY)
        XCTAssertFalse(
            sheets[0].frame.intersects(sheets[1].frame), "two sheets cannot overlap"
        )
        for sheet in sheets {
            XCTAssertGreaterThan(sheet.frame.width, 0)
            XCTAssertEqual(
                sheet.frame.height, sheet.metrics.totalHeight, accuracy: 1,
                "a sheet has to be as tall as the cells it says it holds"
            )
        }

        // And a band drawn across the seam, in those very coordinates, takes rows from
        // both — which is the thing that was broken.
        let band = CGRect(
            x: sheets[0].frame.minX,
            y: sheets[0].frame.maxY - sheets[0].metrics.cellHeight / 2,
            width: sheets[0].frame.width,
            height: (sheets[1].frame.minY - sheets[0].frame.maxY)
                + sheets[0].metrics.cellHeight
        )
        let hits = ClipMarqueeResolver.hits(in: band, sheets: sheets)
        XCTAssertTrue(hits.contains { $0 < 12 }, "nothing from the first sheet")
        XCTAssertTrue(hits.contains { $0 >= 12 }, "nothing from the second sheet")
    }

    /// A picture deleted from inside a long run, with the panel up — which is what a
    /// batch delete, or a purge, does.
    ///
    /// The block below the deleted row goes from `12..<17` to `12..<16` and changes
    /// nothing a view can be identified by: its first row is untouched, so `ForEach`
    /// keeps the same view and never runs `onAppear`; five pictures and four are both
    /// two lines, so its frame does not move and a frame-only watch never fires either.
    /// The model was left holding a range the list no longer has, which it rightly
    /// refuses to trust — and the sheet, still on screen, answered no rubber band until
    /// the panel was closed and reopened.
    func testASheetThatLosesARowKeepsAnsweringTheRubberBand() {
        let harness = Harness()
        let pictures = Self.pictures(count: 17)
        let model = seededModel(label: "reshape", records: pictures, harness: harness)
        let window = host(ClipboardPanelView(model: model, actions: Self.inertActions()))
        settle(window, seconds: 0.4)
        XCTAssertEqual(model.blocks.map(\.indices), [0..<12, 12..<17])
        XCTAssertEqual(model.sheetRegistrations.map(\.range), [0..<12, 12..<17])
        let before = model.sheetRegistrations[1].frame

        var shorter = pictures
        shorter.remove(at: 14)
        model.query = "种子二"
        spin(until: { !harness.completions.isEmpty }, timeout: 3)
        harness.completions.removeLast()(
            .success(ClipSearchOutcome(records: shorter, terms: [], contexts: [:]))
        )
        spin(until: { model.results.count == shorter.count }, timeout: 3)
        settle(window, seconds: 0.4)

        XCTAssertEqual(model.blocks.map(\.indices), [0..<12, 12..<16])
        XCTAssertEqual(
            model.sheetRegistrations.map(\.range), [0..<12, 12..<16],
            "the sheet on screen stopped saying which rows it holds"
        )
        // Every assertion below is about the second sheet, and the regression this test
        // exists for is precisely that it is missing — so ask rather than subscript, or
        // a regression takes the whole test process down with it and loses every other
        // result in the run.
        guard model.sheetRegistrations.count > 1 else {
            return XCTFail("the second sheet never registered")
        }
        let sheet = model.sheetRegistrations[1]
        // The premise of the test, stated: nothing a frame-only watch could have seen.
        XCTAssertEqual(sheet.frame, before)

        model.applyMarquee(sheet.frame)
        XCTAssertEqual(
            model.checked.count, 4, "a band over the whole sheet selected nothing"
        )
        XCTAssertTrue(model.checked.contains(shorter[15].id))
    }

    private static func pictures(count: Int) -> [ClipRecord] {
        let now = Date()
        return (0..<count).map { index in
            let id = UUID()
            return ClipRecord(
                id: id, createdAt: now, kind: .image, preview: "图片 \(index)",
                digest: "sheet-\(id.uuidString)", byteSize: 4096,
                sourceBundleID: "com.example.shot", sourceName: "Shot",
                hasThumbnail: true, pixelWidth: 800, pixelHeight: 600
            )
        }
    }

    // MARK: - Cost of sweeping the pointer down the list

    /// What "有点拖影" is, as a number: how long one row crossed costs, with the real
    /// panel hosted and laid out.
    ///
    /// The pointer walking the list is the busiest thing the panel ever does — every row
    /// it crosses is a `hover`, which publishes, which invalidates the panel and lays it
    /// out again. 1.4.1 measured this at 10.6ms a row before the pill row was taken off
    /// the layout path and 3.1ms after. It is a reading rather than a threshold: the
    /// assertion below is a very loose ceiling, so the test reports a regression of
    /// character rather than failing on a busy machine.
    func testHoverSweepCostPerRowIsReported() {
        let model = seededModel(label: "sweep", records: Self.longHistory(count: 60))
        let window = host(ClipboardPanelView(model: model, actions: Self.inertActions()))
        // The panel only lets a hover steer once the pointer has really moved; the sweep
        // below is measuring the published-change cost either way.
        settle(window)

        // A pass that is thrown away: the first crossing pays for the lazy stack
        // materialising rows and for the first decode of every attribute it touches.
        for index in 0..<10 {
            model.hover(index)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }

        let rows = 50
        let started = Date()
        for step in 0..<rows {
            model.hover(step % model.results.count)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        let perRow = Date().timeIntervalSince(started) / Double(rows) * 1000

        print("HOVER-SWEEP per-row: \(String(format: "%.2f", perRow))ms over \(rows) rows")
        XCTAssertLessThan(perRow, 60, "a row crossed should not cost tens of milliseconds")
    }

    /// A history long enough to sweep: mostly one-line text rows, with a contact sheet
    /// and a few link/file rows so the derived-value paths are exercised too.
    private static func longHistory(count: Int) -> [ClipRecord] {
        let now = Date()
        func make(_ kind: ClipKind, _ preview: String, files: Int? = nil) -> ClipRecord {
            let id = UUID()
            return ClipRecord(
                id: id, createdAt: now, kind: kind, preview: preview,
                digest: "sweep-\(id.uuidString)", byteSize: preview.utf8.count,
                sourceBundleID: "com.example.app", sourceName: "示例",
                pixelWidth: kind == .image ? 800 : nil,
                pixelHeight: kind == .image ? 600 : nil,
                fileCount: files
            )
        }
        var records: [ClipRecord] = []
        for index in 0..<count {
            switch index % 10 {
            case 3:
                records.append(make(.url, "https://example.com/path/\(index)?q=\(index)"))
            case 7:
                records.append(make(.files, "/tmp/素材/文件-\(index).zip", files: 1))
            default:
                records.append(make(.text, "第 \(index) 条剪贴板内容，用来把这一行撑到普通长度"))
            }
        }
        return records
    }

    // MARK: - Harness

    private func seededModel(
        label: String, records: [ClipRecord]? = nil, harness: Harness? = nil
    ) -> ClipboardPanelModel {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-render-\(label)-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(location)
        let store = ClipStore(root: location)
        let loaded = expectation(description: "loaded")
        let filters = expectation(description: "filters")
        store.whenLoaded { loaded.fulfill() }
        store.whenSmartFiltersLoaded { filters.fulfill() }
        wait(for: [loaded, filters], timeout: 10)

        let queue = PasteQueue(storeURL: location.appendingPathComponent("queue.json"))
        queue.restore()
        let manager = ClipboardManager(store: store, queue: queue)
        managers.append(manager)

        let harness = harness ?? Harness()
        let model = ClipboardPanelModel(
            manager: manager,
            searchExecutor: { _, _, completion in
                harness.completions.append(completion)
                return ClipSearchCancellationToken()
            }
        )
        let records = records ?? Self.mixedHistory()
        model.query = "种子"
        spin(until: { !harness.completions.isEmpty }, timeout: 3)
        harness.completions.removeLast()(
            .success(ClipSearchOutcome(records: records, terms: [], contexts: [:]))
        )
        spin(until: { model.results.count == records.count }, timeout: 3)
        return model
    }

    /// Nine pictures — three lines of contact sheet — then one row of every other kind,
    /// so each tab it is narrowed to holds a different, much shorter list.
    private static func mixedHistory() -> [ClipRecord] {
        let now = Date()
        func make(_ kind: ClipKind, _ preview: String, files: Int? = nil) -> ClipRecord {
            let id = UUID()
            return ClipRecord(
                id: id, createdAt: now, kind: kind, preview: preview,
                digest: "render-\(id.uuidString)", byteSize: preview.utf8.count,
                sourceBundleID: "com.example.app", sourceName: "示例",
                pixelWidth: kind == .image ? 800 : nil,
                pixelHeight: kind == .image ? 600 : nil,
                fileCount: files
            )
        }
        var records = (0..<9).map { make(.image, "图片 \($0)") }
        records.append(make(.text, "一段够长的文字，用来撑开被选中那一行的三行展开"))
        records.append(make(.url, "https://example.com/a/b?c=d"))
        records.append(make(.files, "/tmp/素材包.zip", files: 1))
        return records
    }

    private func host<Content: View>(_ content: Content) -> NSWindow {
        let size = CGSize(width: 400, height: 740)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        windows.append(window)
        settle(window)
        return window
    }

    /// Lays the view out and lets SwiftUI's transactions drain — which is where the
    /// crash was, so it has to actually happen rather than be assumed.
    private func settle(_ window: NSWindow, seconds: TimeInterval = 0.25) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func spin(until predicate: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func inertActions() -> ClipboardPanelActions {
        ClipboardPanelActions(
            paste: { _ in }, pasteKeepingOpen: {}, pasteAs: { _ in }, pasteTransformed: { _ in },
            copyOnly: {}, returnAction: {}, enqueue: {}, delete: {}, dequeue: {}, togglePin: {},
            clearQueue: {}, removeFromQueue: { _ in }, moveInQueue: { _, _ in },
            toggleShortcuts: {}, toggleChecked: { _ in }, togglePinRow: { _ in },
            deleteRow: { _ in }, dequeueRow: { _ in }, selectIndex: { _ in },
            activateRow: { _ in }, hoverIndex: { _ in }, hoverEnded: { _ in }, edit: {},
            dragBegan: { _ in NSItemProvider() }, movePinnedRow: { _ in },
            reorderPinned: { _, _ in }, saveDropped: { _ in }, dismissOnboarding: {},
            retryPaste: {}, skipInvalidPaste: {}, openAccessibilitySettings: {},
            dismissPasteIssue: {}, close: {}
        )
    }
}
