import AppKit
import SwiftUI
import XCTest

@testable import Hyper

final class ClipboardPanelQueryTests: XCTestCase {
    private final class SearchHarness {
        struct Request {
            let query: String
            let queuedIDs: Set<UUID>
            let token: ClipSearchCancellationToken
            let completion: (Result<ClipSearchOutcome, ClipQueryParseError>) -> Void
        }

        private(set) var requests: [Request] = []

        func execute(
            _ query: String, queuedIDs: Set<UUID>,
            completion: @escaping (Result<ClipSearchOutcome, ClipQueryParseError>) -> Void
        ) -> ClipSearchCancellationToken? {
            let token = ClipSearchCancellationToken()
            requests.append(Request(
                query: query, queuedIDs: queuedIDs, token: token, completion: completion
            ))
            return token
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
            "hyper-panel-query-\(label)-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(url)
        return url
    }

    private func loadedStore(at root: URL, loadQueue: DispatchQueue? = nil) -> ClipStore {
        let store = ClipStore(root: root, loadQueue: loadQueue)
        let loaded = expectation(description: "store loaded")
        let filters = expectation(description: "smart filters loaded")
        store.whenLoaded { loaded.fulfill() }
        store.whenSmartFiltersLoaded { filters.fulfill() }
        wait(for: [loaded, filters], timeout: 5)
        return store
    }

    private func manager(store: ClipStore, root: URL) -> ClipboardManager {
        let queue = PasteQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.restore()
        return ClipboardManager(store: store, queue: queue)
    }

    private func insertion(
        _ text: String, source: String = "Editor", kind: ClipKind = .text
    ) -> ClipStore.Insertion {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        return ClipStore.Insertion(
            payload: payload, kind: kind, oversized: false,
            byteSize: ClipPayloadCoder.byteSize(payload),
            sourceBundleID: "com.example.editor", sourceName: source
        )
    }

    private func record(_ text: String, id: UUID = UUID()) -> ClipRecord {
        ClipRecord(
            id: id, createdAt: Date(), kind: .text, preview: text,
            digest: "query-test-\(id.uuidString)", byteSize: text.utf8.count,
            sourceBundleID: "com.example.editor", sourceName: "Editor"
        )
    }

    private func outcome(_ records: [ClipRecord], terms: [String]) -> ClipSearchOutcome {
        ClipSearchOutcome(records: records, terms: terms, contexts: [:])
    }

    @discardableResult
    private func spin(
        timeout: TimeInterval = 2, until predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    func testDebounceCancelsSupersededQueryAndLateCompletionCannotReplaceNewResult() {
        let location = root("debounce")
        let store = loadedStore(at: location)
        let manager = manager(store: store, root: location)
        let harness = SearchHarness()
        let model = ClipboardPanelModel(
            manager: manager,
            searchExecutor: { harness.execute($0, queuedIDs: $1, completion: $2) }
        )

        model.query = "a"
        model.query = "al"
        model.query = "alpha"
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        XCTAssertEqual(harness.requests.map(\.query), ["alpha"], "typing must debounce")

        let alpha = harness.requests[0]
        model.query = "beta"
        XCTAssertTrue(alpha.token.isCancelled, "new input cancels work before its debounce")
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        XCTAssertEqual(harness.requests.map(\.query), ["alpha", "beta"])

        let betaRecord = record("beta result")
        harness.requests[1].completion(.success(outcome([betaRecord], terms: ["beta"])))
        alpha.completion(.success(outcome([record("stale alpha")], terms: ["alpha"])))
        XCTAssertTrue(spin { model.results.map(\.id) == [betaRecord.id] })
        XCTAssertEqual(model.highlightTerms, ["beta"])
        XCTAssertFalse(model.isSearchLoading)
    }

    func testSyntaxErrorIsLocatedImmediatelyAndKeepsLastStableResult() {
        let location = root("syntax")
        let store = loadedStore(at: location)
        let manager = manager(store: store, root: location)
        let harness = SearchHarness()
        let model = ClipboardPanelModel(
            manager: manager,
            searchExecutor: { harness.execute($0, queuedIDs: $1, completion: $2) }
        )
        let stable = record("quarterly plan")

        model.query = "quarterly"
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        harness.requests[0].completion(.success(outcome([stable], terms: ["quarterly"])))
        XCTAssertTrue(spin { model.results.map(\.id) == [stable.id] })

        model.query = #"app:"unterminated"#
        XCTAssertEqual(model.queryIssue?.position, 4)
        XCTAssertTrue(model.queryIssue?.localizedDescription.contains("位置 5") == true)
        XCTAssertEqual(model.results.map(\.id), [stable.id], "a field error is not zero matches")
        XCTAssertEqual(model.highlightTerms, ["quarterly"])
        XCTAssertFalse(model.isSearchLoading)
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        XCTAssertEqual(harness.requests.count, 1, "invalid syntax must not reach the backend")
    }

    func testAdvancedCombinationUsesRealQueueIDsAndTabsRemainLocalNarrowing() {
        let location = root("advanced")
        let store = loadedStore(at: location)
        let manager = manager(store: store, root: location)
        let wanted = store.insert(insertion("quarterly plan final", source: "Google Chrome"))
        let notQueued = store.insert(insertion("quarterly plan notes", source: "Google Chrome"))
        let draft = store.insert(insertion("quarterly plan draft", source: "Google Chrome"))
        let wrongApp = store.insert(insertion("quarterly plan final safari", source: "Safari"))
        for record in [wanted, notQueued, draft, wrongApp] { store.togglePin(record.id) }
        manager.enqueue([wanted.id, draft.id, wrongApp.id])
        store.waitForPendingWrites()
        let model = ClipboardPanelModel(manager: manager)

        model.query = #""quarterly plan" -draft app:"Google Chrome" type:text is:pinned is:queued"#
        XCTAssertTrue(spin(timeout: 3) { !model.isSearchLoading })
        XCTAssertNil(model.queryIssue)
        XCTAssertEqual(model.results.map(\.id), [wanted.id])
        XCTAssertEqual(model.highlightTerms, ["quarterly plan"])
        XCTAssertEqual(model.filterCounts[.all], 1)
        XCTAssertEqual(model.filterCounts[.queue], 1)
        XCTAssertEqual(model.filterCounts[.pinned], 1)
        XCTAssertEqual(model.filterCounts[.text], 1)

        model.filter = .queue
        XCTAssertEqual(model.results.map(\.id), [wanted.id])
        model.filter = .url
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.filterCounts[.all], 1, "tab switches reuse the full query outcome")
        model.filter = .all
        XCTAssertEqual(model.results.map(\.id), [wanted.id])
        XCTAssertEqual(model.queuedIDs, Set([wanted.id, draft.id, wrongApp.id]))
        XCTAssertFalse(model.queuedIDs.contains(notQueued.id))
    }

    func testPinyinAndFuzzyResultsExposeVisibleMatchReasons() {
        let location = root("match-explanation")
        let store = loadedStore(at: location)
        let manager = manager(store: store, root: location)
        let chinese = store.insert(insertion("剪贴板专业工作流"))
        let fuzzy = store.insert(insertion("quarterly planning document"))
        let model = ClipboardPanelModel(manager: manager)

        model.query = "jiantieban"
        XCTAssertTrue(spin(timeout: 3) { !model.isSearchLoading })
        XCTAssertEqual(model.results.map(\.id), [chinese.id])
        XCTAssertEqual(model.matchExplanations[chinese.id]?.first?.kind, .pinyin)
        let pinyinNote = model.visibleMatchExplanation(for: chinese.id)
        XCTAssertTrue(pinyinNote?.contains("拼音匹配：jiantieban") == true)
        XCTAssertTrue(pinyinNote?.contains("→") == true)

        model.query = "quaterly"
        XCTAssertTrue(spin(timeout: 3) {
            !model.isSearchLoading && model.results.map(\.id) == [fuzzy.id]
        })
        XCTAssertEqual(model.matchExplanations[fuzzy.id]?.first?.kind, .fuzzy)
        XCTAssertEqual(
            model.visibleMatchExplanation(for: fuzzy.id),
            "模糊匹配：quaterly ≈ quarterly"
        )
    }

    func testNotReadyStoreShowsLoadingInsteadOfEmptyAndAdoptsLoadedHistory() {
        let location = root("startup")
        var first: ClipStore? = loadedStore(at: location)
        _ = first?.insert(insertion("durable launch result"))
        first?.waitForPendingWrites()
        first = nil

        let gate = DispatchSemaphore(value: 0)
        let delayedQueue = DispatchQueue(label: "tests.panel-query-delayed-load")
        delayedQueue.async { _ = gate.wait(timeout: .now() + 5) }
        let store = ClipStore(root: location, loadQueue: delayedQueue)
        let manager = manager(store: store, root: location)
        let model = ClipboardPanelModel(manager: manager)
        defer { gate.signal() }

        XCTAssertFalse(store.isLoaded)
        XCTAssertTrue(model.isSearchLoading)
        XCTAssertTrue(model.results.isEmpty)

        gate.signal()
        XCTAssertTrue(spin(timeout: 5) { store.isLoaded && !model.isSearchLoading })
        XCTAssertEqual(model.results.map(\.preview), ["durable launch result"])
    }

    func testPanelOpenedDuringSlowSmartFilterLoadRefreshesFromCompletionSignal() throws {
        let location = root("slow-smart-filters")
        var seed: ClipStore? = loadedStore(at: location)
        _ = try seed?.saveSmartFilter(name: "慢盘工作流", query: #"app:"Safari" is:pinned"#)
        seed?.waitForPendingWrites()
        seed = nil

        let filterGate = DispatchSemaphore(value: 0)
        let delayedQueue = DispatchQueue(label: "tests.panel-query-filter-load")
        // Freeze the queue while ordering its work: ClipStore's history load is already
        // first; this blocker becomes second; the filter read scheduled from history
        // adoption is therefore third and cannot race the assertion below.
        delayedQueue.suspend()
        let store = ClipStore(root: location, loadQueue: delayedQueue)
        delayedQueue.async { _ = filterGate.wait(timeout: .now() + 5) }
        let manager = manager(store: store, root: location)
        let model = ClipboardPanelModel(manager: manager)
        model.panelWillShow()
        delayedQueue.resume()
        defer {
            filterGate.signal()
            model.panelDidHide()
        }

        XCTAssertTrue(spin(timeout: 3) { store.isLoaded })
        XCTAssertFalse(store.areSmartFiltersLoaded)
        XCTAssertFalse(model.areSmartFiltersReady)
        XCTAssertTrue(model.smartFilters.isEmpty)
        // This exceeds the deleted 100 ms guess. Nothing should pretend that the
        // pending sidecar is an empty saved-filter library.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(model.areSmartFiltersReady)
        XCTAssertTrue(model.smartFilters.isEmpty)

        filterGate.signal()
        XCTAssertTrue(spin(timeout: 5) {
            model.areSmartFiltersReady && model.smartFilters.map(\.name) == ["慢盘工作流"]
        })
    }

    func testSavedFilterLifecycleIsEncryptedAndReloadedOnNormalRestart() throws {
        let location = root("saved")
        var store: ClipStore? = loadedStore(at: location)
        var manager: ClipboardManager? = manager(store: try XCTUnwrap(store), root: location)
        var model: ClipboardPanelModel? = ClipboardPanelModel(manager: try XCTUnwrap(manager))

        model?.query = #"app:"Safari" is:pinned"#
        XCTAssertTrue(try XCTUnwrap(model).saveCurrentSmartFilter(named: "工作收藏"))
        let first = try XCTUnwrap(model?.smartFilters.first)
        XCTAssertEqual(model?.activeSmartFilterName, "工作收藏")

        model?.query = "type:image"
        XCTAssertNil(model?.activeSmartFilterID)
        XCTAssertTrue(try XCTUnwrap(model).applySmartFilter(first.id))
        XCTAssertEqual(model?.query, #"app:"Safari" is:pinned"#)
        XCTAssertTrue(try XCTUnwrap(model).renameSmartFilter(first.id, to: "Safari 收藏"))
        XCTAssertEqual(model?.smartFilters.first?.id, first.id)
        XCTAssertEqual(model?.smartFilters.first?.name, "Safari 收藏")

        model?.query = "is:queued -type:image"
        XCTAssertTrue(try XCTUnwrap(model).saveCurrentSmartFilter(named: "队列非图片"))
        let second = try XCTUnwrap(model?.smartFilters.first { $0.name == "队列非图片" })
        XCTAssertTrue(try XCTUnwrap(model).deleteSmartFilter(first.id))
        XCTAssertEqual(model?.smartFilters.map(\.id), [second.id])

        let sidecar = location.appendingPathComponent("smart-filters.json")
        let sealed = try Data(contentsOf: sidecar)
        XCTAssertTrue(ClipboardVault.isSealed(sealed))
        XCTAssertNil(String(data: sealed, encoding: .utf8)?.range(of: "队列非图片"))

        model = nil
        manager = nil
        store = nil
        let reopened = loadedStore(at: location)
        XCTAssertTrue(spin(timeout: 3) { !reopened.smartFilters.filters.isEmpty })
        XCTAssertEqual(reopened.smartFilters.filters.map(\.id), [second.id])
        XCTAssertEqual(reopened.smartFilters.filters.map(\.query), ["is:queued -type:image"])
    }

    func testTokenExamplesAndNativeSearchFieldExposeQueryableAXFocusAndShortcuts() {
        let location = root("accessibility")
        let store = loadedStore(at: location)
        let manager = manager(store: store, root: location)
        let model = ClipboardPanelModel(manager: manager)

        XCTAssertGreaterThanOrEqual(ClipboardPanelModel.querySuggestionCatalog.count, 6)
        let app = ClipboardPanelModel.querySuggestionCatalog[0]
        model.insertQuerySuggestion(app)
        let parsed = try? ClipQueryParser.parse(model.query)
        XCTAssertEqual(parsed?.appTerms.map(\.value), ["safari"])
        XCTAssertEqual(parsed?.appTerms.map(\.phrase), [true])

        model.query = "type:"
        XCTAssertTrue(model.querySuggestions.contains { $0.token == "type:image" })
        model.insertQuerySuggestion(
            try! XCTUnwrap(model.querySuggestions.first { $0.token == "type:image" })
        )
        XCTAssertEqual(model.query, "type:image")
        XCTAssertEqual(try? ClipQueryParser.parse(model.query).kinds, [.image])

        model.query = #"app:"unterminated"#
        let invalidIssue = model.queryIssue
        XCTAssertNotNil(invalidIssue)
        let hosting = NSHostingView(
            rootView: ClipboardPanelView(model: model, actions: .queryNoop)
                .frame(width: 520, height: 560)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()

        let searchField = try? XCTUnwrap(
            descendants(of: hosting).compactMap { $0 as? PanelSearchTextField }.first
        )
        let bitmap = try? XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        if let bitmap { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
        let renderedBytes = bitmap?.representation(using: .png, properties: [:])?.count ?? 0
        XCTAssertGreaterThan(renderedBytes, 10_000, "the real error/header UI must render")
        XCTAssertNotNil(searchField)
        XCTAssertEqual(searchField?.accessibilityRole(), .textField)
        XCTAssertEqual(searchField?.accessibilitySubrole(), .searchField)
        XCTAssertEqual(searchField?.accessibilityLabel(), "搜索剪贴板历史")
        XCTAssertEqual(searchField?.accessibilityHelp(), PanelSearchAccessibility.fieldHint)
        XCTAssertEqual(searchField?.accessibilityIdentifier(), "clipboard-search-field")
        if let searchField {
            XCTAssertTrue(window.makeFirstResponder(searchField))
            XCTAssertTrue(
                window.firstResponder === searchField
                    || window.firstResponder === searchField.currentEditor(),
                "the actual panel window must focus the query control"
            )

            model.query = ""
            XCTAssertTrue(searchField.performKeyEquivalent(with: shortcutEvent("f", keyCode: 3)))
            XCTAssertEqual(model.query, #"app:"Safari""#)
        }

        // Exercise the product subclass itself for both routes. The SwiftUI menu is not
        // semantically exported by a headless host, while this focused AppKit path is.
        var syntaxRoutes = 0
        var savedFilterRoutes = 0
        let shortcutProbe = PanelSearchTextField()
        shortcutProbe.openSyntax = { syntaxRoutes += 1 }
        shortcutProbe.openSavedFilters = { savedFilterRoutes += 1 }
        XCTAssertTrue(shortcutProbe.performKeyEquivalent(with: shortcutEvent("f", keyCode: 3)))
        XCTAssertTrue(shortcutProbe.performKeyEquivalent(with: shortcutEvent("s", keyCode: 1)))
        XCTAssertEqual(syntaxRoutes, 1)
        XCTAssertEqual(savedFilterRoutes, 1)

        if let invalidIssue {
            XCTAssertEqual(
                PanelSearchAccessibility.queryError(invalidIssue),
                "搜索语法错误，位置 5：引号未闭合"
            )
        }
        window.orderOut(nil)
    }

    func testDeleteConfirmationHasNativeAXButtonsAndKeyboardRoutes() throws {
        let location = root("delete-confirmation-ax")
        let store = loadedStore(at: location)
        let manager = manager(store: store, root: location)
        let model = ClipboardPanelModel(manager: manager)
        model.query = "type:image"
        XCTAssertTrue(model.saveCurrentSmartFilter(named: "待删除筛选"))
        let saved = try XCTUnwrap(model.smartFilters.first)
        model.requestSmartFilterDeletion(saved)

        let hosting = NSHostingView(
            rootView: ClipboardPanelView(model: model, actions: .queryNoop)
                .frame(width: 520, height: 560)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(spin {
            self.descendants(of: hosting).contains { $0 is PanelDeleteConfirmationBar }
        })
        let bar = try XCTUnwrap(
            descendants(of: hosting).compactMap { $0 as? PanelDeleteConfirmationBar }.first
        )
        XCTAssertEqual(bar.accessibilityRole(), .group)
        XCTAssertEqual(bar.accessibilityLabel(), "删除已保存筛选确认")
        XCTAssertEqual(bar.accessibilityHelp(), "确认只删除筛选，不删除剪贴板历史")
        XCTAssertEqual(bar.cancelButton.accessibilityRole(), .button)
        XCTAssertEqual(bar.cancelButton.accessibilityLabel(), "取消删除筛选")
        XCTAssertEqual(bar.cancelButton.accessibilityHelp(), "保留这个已保存筛选")
        XCTAssertEqual(bar.cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertEqual(bar.deleteButton.accessibilityRole(), .button)
        XCTAssertEqual(bar.deleteButton.accessibilityLabel(), "确认删除筛选")
        XCTAssertEqual(bar.deleteButton.accessibilityHelp(), "删除筛选，不删除剪贴板历史")
        XCTAssertEqual(bar.deleteButton.keyEquivalent, "\r")

        bar.cancelButton.performClick(nil)
        XCTAssertTrue(spin { model.pendingSmartFilterDeletion == nil })
        XCTAssertEqual(model.smartFilters.map(\.id), [saved.id])
        model.requestSmartFilterDeletion(saved)
        XCTAssertTrue(model.handleSmartFilterDeletionKey(53), "Escape cancels from local monitor")
        XCTAssertNil(model.pendingSmartFilterDeletion)
        XCTAssertEqual(model.smartFilters.map(\.id), [saved.id])
        model.requestSmartFilterDeletion(saved)
        XCTAssertTrue(model.handleSmartFilterDeletionKey(36), "Return confirms from local monitor")
        XCTAssertNil(model.pendingSmartFilterDeletion)
        XCTAssertTrue(model.smartFilters.isEmpty)
        window.orderOut(nil)
    }

    private func shortcutEvent(_ character: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: 0, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
        )!
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}

private extension ClipboardPanelActions {
    static var queryNoop: ClipboardPanelActions {
        ClipboardPanelActions(
            paste: { _ in }, pasteKeepingOpen: {}, pasteAs: { _ in },
            pasteTransformed: { _ in }, copyOnly: {}, returnAction: {}, enqueue: {},
            delete: {}, dequeue: {}, togglePin: {}, clearQueue: {}, removeFromQueue: { _ in },
            moveInQueue: { _, _ in }, toggleShortcuts: {}, toggleChecked: { _ in },
            togglePinRow: { _ in }, deleteRow: { _ in }, dequeueRow: { _ in },
            selectIndex: { _ in }, activateRow: { _ in }, hoverIndex: { _ in },
            hoverEnded: { _ in }, edit: {}, dragBegan: { _ in NSItemProvider() },
            movePinnedRow: { _ in }, reorderPinned: { _, _ in }, saveDropped: { _ in },
            dismissOnboarding: {}, retryPaste: {}, skipInvalidPaste: {},
            openAccessibilitySettings: {}, dismissPasteIssue: {}, close: {}
        )
    }
}
