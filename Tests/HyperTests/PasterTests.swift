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
}
