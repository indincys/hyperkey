import AppKit
import XCTest

@testable import Hyper

/// How much of a text entry a row shows, and when the preview card is allowed to open.
///
/// The rule the panel works to: a row shows its entry in full up to three lines — one
/// line for a one-line entry, two for a two-line one — and the card exists for what three
/// lines could not finish. An entry that fits is already read in the list, so hovering it
/// must open nothing.
///
/// Both halves of that rule are pure functions of a record and a width, so they are
/// pinned here rather than by looking at the panel. The widths used are the ones the real
/// presets produce: 400pt standard, 360pt compact, 480pt large.
final class ClipboardRowTextPolicyTests: XCTestCase {
    private func record(
        _ kind: ClipKind = .text,
        preview: String,
        fileCount: Int? = nil
    ) -> ClipRecord {
        let id = UUID()
        return ClipRecord(
            id: id, createdAt: Date(), kind: kind, preview: preview,
            digest: "row-text-\(id.uuidString)", byteSize: preview.utf8.count,
            sourceBundleID: "com.example.editor", sourceName: "Editor",
            fileCount: fileCount
        )
    }

    /// The widths used below are the text columns the three real panel presets leave:
    /// standard (400), compact (360), large (480).
    private let standard: CGFloat = 249
    private let compact: CGFloat = 209
    private let large: CGFloat = 329

    // MARK: - Column width

    func testEachPanelPresetLeavesItsOwnTextColumn() {
        XCTAssertEqual(ClipRowTextMetrics.textWidth(inPanelWidth: 400), standard)
        XCTAssertEqual(ClipRowTextMetrics.textWidth(inPanelWidth: 360), compact)
        XCTAssertEqual(ClipRowTextMetrics.textWidth(inPanelWidth: 480), large)
    }

    // MARK: - Counting the lines a row will show

    func testAOneLineEntryIsCountedAsOne() {
        XCTAssertEqual(ClipRowTextMetrics.lineCount("这是一条短记录", width: standard), 1)
        XCTAssertEqual(ClipRowTextMetrics.lineCount("A short entry", width: standard), 1)
    }

    /// Wrapped, not split on newlines: the row draws the preview line, which has already
    /// had its runs of whitespace collapsed — see `ClipCapture.collapsedPreview`.
    func testALongEntryIsCountedByHowManyLinesItWrapsTo() {
        XCTAssertEqual(
            ClipRowTextMetrics.lineCount(
                "这是一段中文文本，用来测量每行大概能排多少字。剪贴板里的一条记录，通常会显示三行左右。",
                width: standard
            ),
            3
        )
        XCTAssertEqual(
            ClipRowTextMetrics.lineCount(
                "The quick brown fox jumps over the lazy dog and keeps running past the fence",
                width: standard
            ),
            2
        )
    }

    /// The case a character-count estimate got wrong: one unbroken run has nowhere to
    /// wrap but between characters, and there are more lines of it than its length
    /// suggests.
    func testAnUnbrokenRunIsCountedByItsActualWrap() {
        XCTAssertEqual(ClipRowTextMetrics.lineCount(String(repeating: "a", count: 120), width: standard), 4)
        XCTAssertEqual(ClipRowTextMetrics.lineCount(String(repeating: "a", count: 120), width: large), 3)
    }

    /// A narrower column wraps the same text onto more lines, which is the whole reason
    /// the count is taken at a width rather than stored on the record.
    func testTheSameEntryWrapsToMoreLinesInANarrowerPanel() {
        let entry = "这是一段中文文本，用来测量每行大概能排多少字。剪贴板里的一条记录，通常会显示三行左右。"
        XCTAssertEqual(ClipRowTextMetrics.lineCount(entry, width: large), 2)
        XCTAssertEqual(ClipRowTextMetrics.lineCount(entry, width: standard), 3)
        XCTAssertEqual(ClipRowTextMetrics.lineCount(entry, width: compact), 3)
    }

    // MARK: - When the card is allowed to open

    func testATextEntryThatFitsInThreeLinesNeedsNoCard() {
        XCTAssertFalse(ClipRowTextMetrics.needsPreview("这是一条短记录", width: standard))
        XCTAssertFalse(
            ClipRowTextMetrics.needsPreview(
                "这是一段中文文本，用来测量每行大概能排多少字。剪贴板里的一条记录，通常会显示三行左右。",
                width: standard
            )
        )
    }

    func testATextEntryPastThreeLinesNeedsTheCard() {
        XCTAssertTrue(ClipRowTextMetrics.needsPreview(String(repeating: "中", count: 61), width: standard))
        XCTAssertTrue(ClipRowTextMetrics.needsPreview(String(repeating: "a", count: 120), width: standard))
    }

    /// The row and the card have to agree, so the record-level question is answered from
    /// the same count — and answered only for text.
    func testOnlyTextEntriesAreAskedHowLongTheyAre() {
        let short = "短"
        XCTAssertFalse(ClipRowTextMetrics.needsPreview(record(.text, preview: short), panelWidth: 400))
        XCTAssertFalse(ClipRowTextMetrics.needsPreview(record(.richText, preview: short), panelWidth: 400))

        let long = String(repeating: "中", count: 200)
        XCTAssertTrue(ClipRowTextMetrics.needsPreview(record(.text, preview: long), panelWidth: 400))
        XCTAssertTrue(ClipRowTextMetrics.needsPreview(record(.richText, preview: long), panelWidth: 400))
    }

    /// A picture is a thumbnail in the list however small it is, and a link is its path:
    /// the card is where the whole of either lives, so neither is ever turned away.
    func testEveryOtherKindAlwaysKeepsItsCard() {
        XCTAssertTrue(ClipRowTextMetrics.needsPreview(record(.image, preview: "图片"), panelWidth: 400))
        XCTAssertTrue(ClipRowTextMetrics.needsPreview(record(.url, preview: "https://example.com"), panelWidth: 400))
        XCTAssertTrue(ClipRowTextMetrics.needsPreview(record(.color, preview: "#FF0000"), panelWidth: 400))
        XCTAssertTrue(
            ClipRowTextMetrics.needsPreview(
                record(.files, preview: "报告.pdf", fileCount: 1), panelWidth: 400
            )
        )
    }

    /// The row's own cap is the same number the card's question is asked about; a row
    /// that showed four lines would leave entries nothing to preview.
    func testTheRowCapIsThreeLines() {
        XCTAssertEqual(ClipRowTextMetrics.lineLimit, 3)
    }
}
