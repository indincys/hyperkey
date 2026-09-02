import AppKit
import XCTest

@testable import Hyper

/// What every key press means to the panel, as a value.
///
/// The routing used to live inside an `NSEvent` monitor, where the only way to ask it a
/// question was to synthesize a key event and see what the panel did. It is a pure
/// function now, which is what makes the case below testable at all — and that case is a
/// real bug: with a pinyin candidate window open, ↩ chose a candidate everywhere on the
/// machine except in this panel, where it pasted a row instead.
final class ClipboardPanelKeyRoutingTests: XCTestCase {
    private func input(
        _ keyCode: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false,
        digit: Int? = nil, composing: Bool = false, queryIsEmpty: Bool = true,
        selectionInGrid: Bool = false
    ) -> ClipPanelKeyInput {
        ClipPanelKeyInput(
            keyCode: keyCode, command: command, shift: shift, option: option, digit: digit,
            composing: composing, queryIsEmpty: queryIsEmpty, selectionInGrid: selectionInGrid
        )
    }

    // MARK: - Input methods

    /// The whole of the bug: every key a candidate window needs has to reach it.
    func testWhileComposingTheKeysACandidateWindowNeedsAreLetThrough() {
        for keyCode in [UInt16(36), 76, 125, 126, 53, 48] {
            XCTAssertEqual(
                ClipPanelKeyRouter.action(for: input(keyCode, composing: true)),
                .passThrough,
                "key \(keyCode) was swallowed while an input method had marked text"
            )
            XCTAssertTrue(
                ClipPanelKeyRouter.belongsToInputMethod(input(keyCode, composing: true))
            )
        }
    }

    /// The same keys, with nothing being composed, are the panel's own — or the fix
    /// would be "the panel no longer has a keyboard".
    func testTheSameKeysAreThePanelsOwnWhenNothingIsBeingComposed() {
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(36)), .returnKey(option: false, command: false)
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(76)), .returnKey(option: false, command: false)
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(125)), .moveVertically(1, extending: false)
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(126)), .moveVertically(-1, extending: false)
        )
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(53)), .escape)
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(48)), .cycleFilter(backwards: false))
    }

    /// ⌘ is not part of any composition, and a ⌘Z that stopped working because a
    /// candidate list happened to be open would be a second bug.
    func testCommandShortcutsStillWorkWhileComposing() {
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(6, command: true, composing: true)), .undoDelete
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(8, command: true, composing: true)), .copyOnly
        )
        XCTAssertFalse(
            ClipPanelKeyRouter.belongsToInputMethod(input(6, command: true, composing: true))
        )
    }

    /// A plain letter was never the panel's anyway; composing or not, it is typing.
    func testOrdinaryTypingIsNotTheRoutersBusiness() {
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(2)), .passThrough)
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(2, composing: true)), .passThrough)
    }

    // MARK: - Everything else the field also wants

    /// With a query in the field these are the text cursor's keys, and taking them would
    /// leave no way back to the front of a query to fix it.
    func testTheFieldKeepsItsOwnKeysWhileSomethingIsTyped() {
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(115, queryIsEmpty: false)), .passThrough)
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(119, queryIsEmpty: false)), .passThrough)
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(123, queryIsEmpty: false)), .passThrough)
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(124, queryIsEmpty: false)), .passThrough)
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(0, command: true, queryIsEmpty: false)),
            .passThrough, "⌘A with a query typed is the field's own select-all"
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(44, shift: true, queryIsEmpty: false)),
            .passThrough, "? with a query typed is a character being typed"
        )
    }

    /// Inside a contact sheet ← and → step along the line; outside one they are the
    /// preview's.
    func testArrowsBelongToTheGridOnlyInsideOne() {
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(124)), .pinPreview)
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(123)), .unpinPreview)
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(124, selectionInGrid: true)),
            .move(by: 1, extending: false)
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(123, shift: true, selectionInGrid: true)),
            .move(by: -1, extending: true)
        )
    }

    func testPagingAndEndsAndTheRemainingCommandKeys() {
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(116)),
            .move(by: -ClipPanelKeyRouter.pageStep, extending: false)
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(121, shift: true)),
            .move(by: ClipPanelKeyRouter.pageStep, extending: true)
        )
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(126, command: true)), .moveToEdge(-1))
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(125, command: true)), .moveToEdge(1))
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(51, command: true)), .deleteOrDequeue)
        XCTAssertEqual(ClipPanelKeyRouter.action(for: input(35, command: true)), .togglePin)
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(40, command: true, shift: true)), .clearQueue
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(18, command: true, digit: 3)), .pasteRow(2)
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(18, digit: 3)), .passThrough,
            "a digit without ⌘ is a digit"
        )
    }

    /// ↩ carries its modifiers rather than resolving them: which of paste and copy it
    /// means is a setting read at the moment the key is pressed.
    func testReturnCarriesItsModifiers() {
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(36, command: true)),
            .returnKey(option: false, command: true)
        )
        XCTAssertEqual(
            ClipPanelKeyRouter.action(for: input(36, option: true)),
            .returnKey(option: true, command: false)
        )
    }
}
