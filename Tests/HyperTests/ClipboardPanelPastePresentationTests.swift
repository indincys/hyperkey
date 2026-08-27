import AppKit
import SwiftUI
import XCTest

@testable import Hyper

final class ClipboardPanelPastePresentationTests: XCTestCase {
    func testDetachedModelControllerAndSwiftUIWorkAreSafeAndReleaseForFiftyIterations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-panel-lifecycle-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipStore(root: root)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        let queue = PasteQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.restore()

        for iteration in 0..<50 {
            weak var releasedManager: ClipboardManager?
            weak var releasedModel: ClipboardPanelModel?
            weak var releasedController: ClipboardPanelController?

            autoreleasepool {
                var manager: ClipboardManager? = ClipboardManager(store: store, queue: queue)
                var model: ClipboardPanelModel? = ClipboardPanelModel(
                    manager: try! XCTUnwrap(manager)
                )
                var controller: ClipboardPanelController? = ClipboardPanelController(
                    manager: try! XCTUnwrap(manager)
                )
                var hosting: NSHostingView<ClipboardPanelView>? = NSHostingView(
                    rootView: ClipboardPanelView(
                        model: try! XCTUnwrap(model), actions: .evidenceNoop
                    )
                )
                hosting?.frame = NSRect(x: 0, y: 0, width: 400, height: 540)
                hosting?.layoutSubtreeIfNeeded()
                releasedManager = manager
                releasedModel = model
                releasedController = controller

                manager = nil
                XCTAssertNil(
                    releasedManager, "iteration \(iteration): panel graph retained its manager"
                )

                // These are the two callbacks that used to arrive after the manager died:
                // SwiftUI/query work on the model and a controller entry point.
                model?.query = "detached lifecycle"
                controller?.show()
                hosting?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.14))

                hosting = nil
                model = nil
                controller = nil
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))

            XCTAssertNil(releasedModel, "iteration \(iteration): detached SwiftUI model leaked")
            XCTAssertNil(
                releasedController, "iteration \(iteration): detached panel controller leaked"
            )
        }
    }

    func testBatchPreflightIssueNamesEveryFailureCountAndKeepsRetryLocal() throws {
        let result = ClipboardOperationResult(
            items: [
                ClipboardItemResult(id: UUID(), state: .ready),
                ClipboardItemResult(id: UUID(), state: .failed(.missingPayload)),
                ClipboardItemResult(id: UUID(), state: .failed(.missingPayload)),
                ClipboardItemResult(id: UUID(), state: .failed(.oversized)),
                ClipboardItemResult(id: UUID(), state: .failed(.missingRecord)),
            ],
            failure: .preflightFailed,
            pasteboardChangeCount: nil,
            restore: .notRequested
        )

        let issue = try XCTUnwrap(ClipboardPasteIssue.make(from: result))

        XCTAssertEqual(issue.title, "未粘贴：所选 5 条中有 4 条不可用")
        XCTAssertTrue(issue.detail.contains("缺失内容 2 条"))
        XCTAssertTrue(issue.detail.contains("超过大小限制 1 条"))
        XCTAssertTrue(issue.detail.contains("队列记录缺失 1 条"))
        XCTAssertTrue(issue.detail.contains("整批已取消"))
        XCTAssertTrue(issue.detail.contains("选择仍保留"))
        XCTAssertFalse(issue.offersAccessibilitySettings)
    }

    func testPermissionIssueOffersSettingsAndExplainsInPlaceRetry() throws {
        let result = ClipboardOperationResult(
            items: [ClipboardItemResult(id: UUID(), state: .ready)],
            failure: .accessibilityPermissionDenied,
            pasteboardChangeCount: nil,
            restore: .notRequested
        )

        let issue = try XCTUnwrap(ClipboardPasteIssue.make(from: result))

        XCTAssertEqual(issue.title, "无法粘贴：需要辅助功能权限")
        XCTAssertTrue(issue.detail.contains("内容和选择都已保留"))
        XCTAssertTrue(issue.detail.contains("重新粘贴"))
        XCTAssertTrue(issue.offersAccessibilitySettings)
    }

    func testBatchPreflightIssueCountsIncompatibleItemsAndOffersExplicitSkip() throws {
        let result = ClipboardOperationResult(
            items: [
                ClipboardItemResult(id: UUID(), state: .ready),
                ClipboardItemResult(
                    id: UUID(), state: .failedPreflight(.incompatiblePayload)
                ),
                ClipboardItemResult(
                    id: UUID(), state: .failedPreflight(.incompatiblePayload)
                ),
            ],
            failure: .preflightFailed,
            pasteboardChangeCount: nil,
            restore: .notRequested
        )

        let issue = try XCTUnwrap(ClipboardPasteIssue.make(from: result))

        XCTAssertEqual(issue.title, "未粘贴：所选 3 条中有 2 条不可用")
        XCTAssertTrue(issue.detail.contains("格式不兼容、无法合并为文本 2 条"))
        XCTAssertTrue(issue.detail.contains("默认整批已取消，未粘贴任何条目"))
        XCTAssertTrue(issue.offersSkipInvalid)
    }

    func testAllInvalidBatchDoesNotOfferSkipWithoutAProcessableItem() throws {
        let result = ClipboardOperationResult(
            items: [
                ClipboardItemResult(id: UUID(), state: .failed(.missingPayload)),
                ClipboardItemResult(
                    id: UUID(), state: .failedPreflight(.incompatiblePayload)
                ),
            ],
            failure: .preflightFailed,
            pasteboardChangeCount: nil,
            restore: .notRequested
        )

        let issue = try XCTUnwrap(ClipboardPasteIssue.make(from: result))

        XCTAssertTrue(issue.detail.contains("缺失内容 1 条"))
        XCTAssertTrue(issue.detail.contains("格式不兼容、无法合并为文本 1 条"))
        XCTAssertFalse(issue.offersSkipInvalid)
    }

    func testIncompatibleMergedItemUsesOneBasedPosition() throws {
        let result = ClipboardOperationResult(
            items: [ClipboardItemResult(id: UUID(), state: .ready)],
            failure: .pasteboardWrite(.incompatiblePayload(index: 2)),
            pasteboardChangeCount: nil,
            restore: .notRequested
        )

        let issue = try XCTUnwrap(ClipboardPasteIssue.make(from: result))

        XCTAssertTrue(issue.detail.contains("第 3 条"))
        XCTAssertTrue(issue.detail.contains("选择仍保留"))
    }

    func testSuccessfulOperationHasNoIssue() {
        let result = ClipboardOperationResult(
            items: [ClipboardItemResult(id: UUID(), state: .completed)],
            failure: nil,
            pasteboardChangeCount: 42,
            restore: .notRequested
        )

        XCTAssertNil(ClipboardPasteIssue.make(from: result))
    }

    /// A real SwiftUI render used as the visual acceptance artifact for the permission
    /// recovery state. This does not revoke the developer machine's actual grant.
    func testRenderPermissionFailureEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-panel-evidence-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipStore(root: root)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        let queue = PasteQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.restore()
        let manager = ClipboardManager(store: store, queue: queue)

        for text in ["季度发布检查清单", "用户反馈：粘贴失败时保留选择", "Hyper clipboard"] {
            let payload: ClipPayload = [[
                NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)
            ]]
            _ = store.insert(
                ClipStore.Insertion(
                    payload: payload, kind: .text, oversized: false,
                    byteSize: ClipPayloadCoder.byteSize(payload),
                    sourceBundleID: "com.apple.TextEdit", sourceName: "文本编辑"
                )
            )
        }
        store.waitForPendingWrites()

        let model = ClipboardPanelModel(manager: manager)
        model.reduceMotion = true
        model.refresh(resettingSelection: true)
        model.select(1)
        let checkedID = try XCTUnwrap(model.selected?.id)
        model.toggleChecked(checkedID)
        model.presentPasteIssue(
            ClipboardOperationResult(
                items: [ClipboardItemResult(id: UUID(), state: .ready)],
                failure: .accessibilityPermissionDenied,
                pasteboardChangeCount: nil,
                restore: .notRequested
            )
        )
        XCTAssertEqual(model.selected?.id, checkedID)
        XCTAssertEqual(model.checked, [checkedID])

        let hosting = NSHostingView(
            rootView: ClipboardPanelView(model: model, actions: .evidenceNoop)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("could not allocate panel evidence bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/hyper-wave1-paste-ui.png"), options: .atomic)
        window.orderOut(nil)

        XCTAssertGreaterThan(png.count, 10_000)
    }
}

private extension ClipboardPanelActions {
    static var evidenceNoop: ClipboardPanelActions {
        ClipboardPanelActions(
            paste: { _ in },
            pasteKeepingOpen: {},
            pasteAs: { _ in },
            pasteTransformed: { _ in },
            copyOnly: {},
            returnAction: {},
            enqueue: {},
            delete: {},
            dequeue: {},
            togglePin: {},
            clearQueue: {},
            removeFromQueue: { _ in },
            moveInQueue: { _, _ in },
            toggleShortcuts: {},
            toggleChecked: { _ in },
            togglePinRow: { _ in },
            deleteRow: { _ in },
            dequeueRow: { _ in },
            selectIndex: { _ in },
            activateRow: { _ in },
            hoverIndex: { _ in },
            hoverEnded: { _ in },
            edit: {},
            dragBegan: { _ in NSItemProvider() },
            movePinnedRow: { _ in },
            reorderPinned: { _, _ in },
            saveDropped: { _ in },
            dismissOnboarding: {},
            retryPaste: {},
            skipInvalidPaste: {},
            openAccessibilitySettings: {},
            dismissPasteIssue: {},
            close: {}
        )
    }
}
