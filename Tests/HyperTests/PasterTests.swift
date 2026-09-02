import AppKit
import XCTest

@testable import Hyper

final class PasterTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    func testEmptyPayloadIsRejectedBeforeExistingPasteboardIsChanged() {
        pasteboard.setString("keep", forType: .string)
        let before = pasteboard.changeCount

        let result = Paster.place([], plainTextOnly: false, to: pasteboard)

        guard case .failure(.emptyPayload) = result else {
            return XCTFail("expected empty-payload failure, got \(result)")
        }
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    func testMergedPlacementRejectsOneIncompatiblePayloadWithoutPartialSuccess() {
        pasteboard.setString("keep", forType: .string)
        let text: ClipPayload = [[NSPasteboard.PasteboardType.string.rawValue: Data("one".utf8)]]
        let imageOnly: ClipPayload = [[NSPasteboard.PasteboardType.tiff.rawValue: Data([0, 1, 2])]]
        let before = pasteboard.changeCount

        let result = Paster.placeMerged([text, imageOnly], separator: "\n", to: pasteboard)

        guard case .failure(.incompatiblePayload(index: 1)) = result else {
            return XCTFail("expected incompatible second payload, got \(result)")
        }
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    func testRestoreCASDoesNotOverwriteAUserCopy() throws {
        pasteboard.setString("original", forType: .string)
        let snapshot = Paster.snapshot(pasteboard)
        let payload: ClipPayload = [[NSPasteboard.PasteboardType.string.rawValue: Data("pasted".utf8)]]
        let placed = try XCTUnwrap(try? Paster.place(payload, plainTextOnly: false, to: pasteboard).get())

        pasteboard.clearContents()
        pasteboard.setString("user copied this", forType: .string)
        let result = Paster.restore(
            snapshot, ifUnchangedSince: placed.changeCount, to: pasteboard
        )

        guard case .skippedPasteboardChanged(let expected, let actual) = result else {
            return XCTFail("expected CAS skip, got \(result)")
        }
        XCTAssertEqual(expected, placed.changeCount)
        XCTAssertEqual(actual, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied this")
    }

    func testRestoreCASRestoresWhenPasteboardIsStillOurs() throws {
        pasteboard.setString("original", forType: .string)
        let snapshot = Paster.snapshot(pasteboard)
        let payload: ClipPayload = [[NSPasteboard.PasteboardType.string.rawValue: Data("pasted".utf8)]]
        let placed = try XCTUnwrap(try? Paster.place(payload, plainTextOnly: false, to: pasteboard).get())

        let result = Paster.restore(
            snapshot, ifUnchangedSince: placed.changeCount, to: pasteboard
        )

        guard case .restored = result else { return XCTFail("expected restore, got \(result)") }
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoreDelayAdaptsToPayloadAndTargetCostWithinHardBounds() {
        let small: ClipPayload = [[
            NSPasteboard.PasteboardType.string.rawValue: Data("x".utf8)
        ]]
        let large: ClipPayload = (0..<40).map { _ in
            [NSPasteboard.PasteboardType.string.rawValue: Data(repeating: 7, count: 512 * 1024)]
        }

        let smallLocal = Paster.restoreDelay(
            for: [small], targetActivationRequired: false
        )
        let smallActivated = Paster.restoreDelay(
            for: [small], targetActivationRequired: true
        )
        let largeActivated = Paster.restoreDelay(
            for: [large], targetActivationRequired: true
        )

        XCTAssertGreaterThan(smallActivated, smallLocal)
        XCTAssertGreaterThan(largeActivated, smallActivated)
        XCTAssertGreaterThanOrEqual(smallLocal, Paster.minimumRestoreDelay)
        XCTAssertLessThanOrEqual(largeActivated, Paster.maximumRestoreDelay)
        XCTAssertEqual(largeActivated, Paster.maximumRestoreDelay)
    }

    func testSendPasteReportsEventSourceConstructionFailure() {
        let environment = Paster.EventEnvironment(
            makeSource: { nil },
            makeEvent: { _, _, _ in XCTFail("event creation must not run"); return nil },
            post: { _ in XCTFail("post must not run"); return false }
        )

        let result = Paster.sendPaste(using: environment)

        guard case .failure(.eventSourceUnavailable) = result else {
            return XCTFail("expected source failure, got \(result)")
        }
    }

    func testSendPasteReportsKeyEventConstructionFailureWithoutPostingHalfAChord() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        var posts = 0
        let environment = Paster.EventEnvironment(
            makeSource: { source },
            makeEvent: { source, key, down in
                guard down else { return nil }
                return CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            },
            post: { _ in posts += 1; return true }
        )

        let result = Paster.sendPaste(using: environment)

        guard case .failure(.eventConstructionFailed(keyDown: false)) = result else {
            return XCTFail("expected key-up construction failure, got \(result)")
        }
        XCTAssertEqual(posts, 0, "both events are prepared before either one is posted")
    }

    func testSendPasteReportsPostingFailureAndStillAttemptsKeyUp() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        var directions: [Bool] = []
        let environment = Paster.EventEnvironment(
            makeSource: { source },
            makeEvent: { source, key, down in
                CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            },
            post: { event in
                let down = event.type == .keyDown
                directions.append(down)
                return !down
            }
        )

        let result = Paster.sendPaste(using: environment)

        guard case .failure(.eventPostingFailed(keyDown: true)) = result else {
            return XCTFail("expected key-down post failure, got \(result)")
        }
        XCTAssertEqual(directions, [true, false], "key-up is still attempted after a failed key-down")
    }

    func testPreparedOutputCanBeWrittenWithoutPreparingASecondTime() throws {
        let rtf = try XCTUnwrap(
            NSAttributedString(string: "styled body").data(
                from: NSRange(location: 0, length: 11),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        )
        let payload: ClipPayload = [[
            NSPasteboard.PasteboardType.rtf.rawValue: rtf,
            NSPasteboard.PasteboardType.string.rawValue: Data("styled body".utf8),
        ]]

        for mode in PasteAsMode.allCases {
            let singleShot = NSPasteboard.withUniqueName()
            singleShot.clearContents()
            let reused = NSPasteboard.withUniqueName()
            reused.clearContents()
            defer {
                singleShot.clearContents()
                reused.clearContents()
            }

            let direct = Paster.place(payload, as: mode, to: singleShot)
            let prepared = Paster.prepare(payload, as: mode)
            switch (direct, prepared) {
            case (.success, .success(let output)):
                XCTAssertEqual(output.mode, mode)
                guard case .success = Paster.place(output, to: reused) else {
                    return XCTFail("prepared placement failed for \(mode)")
                }
                let expected = Set((singleShot.pasteboardItems ?? []).flatMap(\.types))
                let actual = Set((reused.pasteboardItems ?? []).flatMap(\.types))
                XCTAssertEqual(actual, expected, "representations differ for \(mode)")
                for type in expected {
                    XCTAssertEqual(
                        reused.data(forType: type), singleShot.data(forType: type),
                        "bytes differ for \(mode)/\(type.rawValue)"
                    )
                }
            case (.failure(let left), .failure(let right)):
                XCTAssertEqual(left, right, "failures differ for \(mode)")
            default:
                XCTFail("prepare and place disagreed for \(mode)")
            }
        }
    }

    func testPreparedPlacementRejectsAnEmptyPayloadTheSameWayTheSingleShotPathDoes() throws {
        pasteboard.setString("keep", forType: .string)
        let before = pasteboard.changeCount
        let prepared = try XCTUnwrap(try? Paster.prepare([], as: .original).get())

        guard case .failure(.emptyPayload) = Paster.place(prepared, to: pasteboard) else {
            return XCTFail("expected an empty-payload failure")
        }
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
        XCTAssertFalse(Paster.isCompatible([[:]], as: .original))
    }
}
