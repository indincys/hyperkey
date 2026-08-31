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

    // MARK: - Harness

    private func seededModel(
        label: String, records: [ClipRecord]? = nil
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

        let harness = Harness()
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
