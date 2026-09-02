import AppKit
import SwiftUI
import XCTest

@testable import Hyper

/// The redesigned list's own arithmetic: how rows are arranged into blocks, and where a
/// rubber band lands when it is dragged over one of them.
///
/// Both are pure functions of values, deliberately. A contact sheet that grouped the
/// wrong rows would put a band header on the wrong pictures, and a marquee that
/// disagreed with the layout by a few points would select pictures nobody dragged over —
/// neither is something to find out by looking at the panel.
final class ClipboardPanelLayoutTests: XCTestCase {
    private func record(
        _ kind: ClipKind, _ preview: String = "x", at date: Date = Date()
    ) -> ClipRecord {
        let id = UUID()
        return ClipRecord(
            id: id, createdAt: date, kind: kind, preview: preview,
            digest: "layout-\(id.uuidString)", byteSize: preview.utf8.count,
            sourceBundleID: "com.example.editor", sourceName: "Editor"
        )
    }

    // MARK: - Blocks

    func testARunOfPicturesLongEnoughToFillALineBecomesAGrid() {
        let records = (0..<6).map { _ in record(.image) }
        let blocks = ClipPanelLayout.blocks(results: records, headers: [:])

        XCTAssertEqual(blocks, [.grid(0..<6)])
    }

    /// Fewer than a full line stays as rows: a contact sheet two-thirds empty says less
    /// than two picture rows do.
    func testAShortRunOfPicturesStaysAsRows() {
        let records = (0..<2).map { _ in record(.image) }
        let blocks = ClipPanelLayout.blocks(results: records, headers: [:])

        XCTAssertEqual(blocks, [.row(0), .row(1)])
    }

    func testExactlyOneLineOfPicturesIsTheThresholdForAGrid() {
        let records = (0..<ClipPanelLayout.minimumGridRun).map { _ in record(.image) }
        XCTAssertEqual(
            ClipPanelLayout.blocks(results: records, headers: [:]), [.grid(0..<records.count)]
        )
    }

    func testTextBetweenPicturesBreaksTheRunIntoSeparateGrids() {
        var records = (0..<3).map { _ in record(.image) }
        records.append(record(.text, "一段文字"))
        records += (0..<4).map { _ in record(.image) }

        XCTAssertEqual(
            ClipPanelLayout.blocks(results: records, headers: [:]),
            [.grid(0..<3), .row(3), .grid(4..<8)]
        )
    }

    /// The band header belongs to whatever opens the band. A grid that reached across a
    /// 今天/昨天 boundary would be filed under one date and hold pictures from two.
    func testAGridNeverReachesAcrossABandHeader() {
        let records = (0..<6).map { _ in record(.image) }
        let blocks = ClipPanelLayout.blocks(results: records, headers: [3: "昨天"])

        XCTAssertEqual(blocks, [.grid(0..<3), .grid(3..<6)])
    }

    /// The queue tab's order *is* the paste order, and a sheet reads as a set rather
    /// than as a sequence.
    func testTheQueueTabKeepsPicturesAsRows() {
        let records = (0..<6).map { _ in record(.image) }
        let blocks = ClipPanelLayout.blocks(results: records, headers: [:], collapseImages: false)

        XCTAssertEqual(blocks, (0..<6).map { ClipPanelBlock.row($0) })
    }

    // MARK: - The cap on one sheet

    /// A block is what the lazy stack virtualises by, and a grid materialises every cell
    /// in it. Uncapped, two hundred screenshots were one block: one child in the stack,
    /// two hundred thumbnails built whether or not any of them were on screen.
    func testALongRunOfPicturesIsCutIntoSeveralSheets() {
        let records = (0..<30).map { _ in record(.image) }
        let blocks = ClipPanelLayout.blocks(results: records, headers: [:])

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(
            blocks,
            [
                .grid(0..<ClipPanelLayout.maxGridRun),
                .grid(ClipPanelLayout.maxGridRun..<(ClipPanelLayout.maxGridRun * 2)),
                .grid((ClipPanelLayout.maxGridRun * 2)..<30),
            ]
        )
    }

    func testNoBlockEverHoldsMoreThanTheCap() {
        for count in [3, 11, 12, 13, 25, 60, 199] {
            let records = (0..<count).map { _ in record(.image) }
            for block in ClipPanelLayout.blocks(results: records, headers: [:]) {
                XCTAssertLessThanOrEqual(
                    block.indices.count, ClipPanelLayout.largestGridRun,
                    "a run of \(count) produced a block of \(block.indices.count)"
                )
            }
        }
    }

    /// The cap is a multiple of the column count, so a sheet never ends mid-line and the
    /// pieces stack into what still reads as one grid.
    func testTheCapIsAWholeNumberOfLines() {
        XCTAssertEqual(ClipPanelLayout.maxGridRun % ClipPanelLayout.gridColumns, 0)
        XCTAssertGreaterThan(ClipPanelLayout.maxGridRun, ClipPanelLayout.minimumGridRun)
    }

    /// A tail too short to be a sheet of its own stays in the sheet before it.
    ///
    /// Cutting strictly at the cap left thirteen pictures as twelve thumbnails and then
    /// one full-width picture row: a visible seam, with the odd one out drawn in a
    /// completely different shape from the twelve above it.
    func testAShortTailStaysInTheSheetBeforeIt() {
        for extra in 1..<ClipPanelLayout.minimumGridRun {
            let count = ClipPanelLayout.maxGridRun + extra
            let records = (0..<count).map { _ in record(.image) }

            XCTAssertEqual(
                ClipPanelLayout.blocks(results: records, headers: [:]), [.grid(0..<count)],
                "\(count) pictures should be one sheet, not a sheet and a stray row"
            )
        }
    }

    /// One picture past that is a line of its own, and becomes a second sheet.
    func testATailOfAFullLineBecomesASheetOfItsOwn() {
        let count = ClipPanelLayout.maxGridRun + ClipPanelLayout.minimumGridRun
        let records = (0..<count).map { _ in record(.image) }

        XCTAssertEqual(
            ClipPanelLayout.blocks(results: records, headers: [:]),
            [.grid(0..<ClipPanelLayout.maxGridRun), .grid(ClipPanelLayout.maxGridRun..<count)]
        )
    }

    /// Whatever the cut, a run of pictures is never drawn as a picture *row*.
    func testALongRunNeverProducesAStrayRow() {
        for count in 3...60 {
            let records = (0..<count).map { _ in record(.image) }
            for block in ClipPanelLayout.blocks(results: records, headers: [:]) {
                XCTAssertTrue(
                    block.isGrid, "a run of \(count) produced a bare row at \(block.start)"
                )
            }
        }
    }

    func testEveryRowOfALongRunIsStillCoveredExactlyOnce() {
        let records = (0..<40).map { _ in record(.image) }
        let covered = ClipPanelLayout.blocks(results: records, headers: [:])
            .flatMap { Array($0.indices) }

        XCTAssertEqual(covered, Array(0..<40))
    }

    /// Blocks are identified by the row that opens them, and that has to survive the
    /// cut — a sheet whose identity changed on every rebuild would transition in as
    /// though it were new every time the list moved.
    func testEachSheetIsIdentifiedByARealRow() {
        let records = (0..<30).map { _ in record(.image) }
        for block in ClipPanelLayout.blocks(results: records, headers: [:]) {
            XCTAssertTrue(records.indices.contains(block.start))
            XCTAssertEqual(block.id, block.indices.lowerBound)
        }
    }

    // MARK: - The run behind the sheets

    /// The cut is a drawing decision and must not become a keyboard decision: ↑↓ inside
    /// a long run of pictures move a line, wherever the sheets happen to have been cut.
    func testTheRunStitchesAdjacentSheetsBackTogether() {
        let records = (0..<30).map { _ in record(.image) }
        let blocks = ClipPanelLayout.blocks(results: records, headers: [:])

        XCTAssertEqual(ClipPanelLayout.gridRun(containing: 0, in: blocks), 0..<30)
        XCTAssertEqual(
            ClipPanelLayout.gridRun(containing: ClipPanelLayout.maxGridRun, in: blocks), 0..<30
        )
        XCTAssertEqual(ClipPanelLayout.gridRun(containing: 29, in: blocks), 0..<30)
    }

    /// But a band header is a real boundary — it is what broke the run in the first
    /// place, and stepping across it is leaving one sheet for another.
    func testTheRunStopsAtABandHeader() {
        let records = (0..<6).map { _ in record(.image) }
        let headers = [3: "昨天"]
        let blocks = ClipPanelLayout.blocks(results: records, headers: headers)

        XCTAssertEqual(blocks, [.grid(0..<3), .grid(3..<6)])
        XCTAssertEqual(
            ClipPanelLayout.gridRun(containing: 1, in: blocks, headers: headers), 0..<3
        )
        XCTAssertEqual(
            ClipPanelLayout.gridRun(containing: 4, in: blocks, headers: headers), 3..<6
        )
    }

    func testARowThatIsNotAPictureHasNoRun() {
        let records = [record(.text, "一"), record(.text, "二")]
        let blocks = ClipPanelLayout.blocks(results: records, headers: [:])

        XCTAssertNil(ClipPanelLayout.gridRun(containing: 0, in: blocks))
    }

    func testEveryRowIsCoveredExactlyOnce() {
        var records = (0..<4).map { _ in record(.image) }
        records.append(record(.files, "/tmp/a.zip"))
        records += (0..<2).map { _ in record(.image) }
        records.append(record(.url, "https://example.com"))

        let covered = ClipPanelLayout.blocks(results: records, headers: [:])
            .flatMap { Array($0.indices) }
        XCTAssertEqual(covered, Array(0..<records.count))
    }

    func testBlockLookupFindsTheSheetAPictureIsIn() {
        let records = (0..<6).map { _ in record(.image) }
        let blocks = ClipPanelLayout.blocks(results: records, headers: [:])

        XCTAssertEqual(ClipPanelLayout.block(containing: 4, in: blocks), .grid(0..<6))
        XCTAssertNil(ClipPanelLayout.block(containing: 9, in: blocks))
    }

    // MARK: - Grid geometry

    func testCellsTileTheSheetWithoutOverlapping() {
        let metrics = ImageGridMetrics(width: 356, count: 6)

        XCTAssertEqual(metrics.rows, 2)
        XCTAssertFalse(metrics.frame(of: 0).intersects(metrics.frame(of: 1)))
        XCTAssertFalse(metrics.frame(of: 0).intersects(metrics.frame(of: 3)))
        // The last cell of a line ends within the sheet it was measured for.
        XCTAssertLessThanOrEqual(metrics.frame(of: 2).maxX, 356)
        XCTAssertEqual(metrics.frame(of: 3).minY, metrics.cellHeight + metrics.gap)
    }

    func testTotalHeightCoversEveryLineIncludingAPartialOne() {
        let metrics = ImageGridMetrics(width: 356, count: 7)

        XCTAssertEqual(metrics.rows, 3)
        XCTAssertEqual(metrics.totalHeight, metrics.frame(of: 6).maxY)
    }

    // MARK: - Marquee

    func testARubberBandOverOneLineSelectsThatLineInListOrder() {
        let metrics = ImageGridMetrics(width: 356, count: 6)
        let band = CGRect(x: 2, y: 2, width: 356, height: metrics.cellHeight - 4)

        XCTAssertEqual(metrics.hits(in: band), [0, 1, 2])
    }

    /// Order is the list's, not the drag's: a band pulled right-to-left still selects
    /// the pictures in the order a batch will act on them, which is what the numbered
    /// badges count.
    func testHitsComeBackInListOrderWhicheverWayTheBandWasDragged() {
        let metrics = ImageGridMetrics(width: 356, count: 6)
        let full = CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight)

        XCTAssertEqual(metrics.hits(in: full), [0, 1, 2, 3, 4, 5])
    }

    func testABandTouchingNothingSelectsNothing() {
        let metrics = ImageGridMetrics(width: 356, count: 3)
        // In the gutter below the only line of cells.
        let band = CGRect(x: 0, y: metrics.cellHeight + 2, width: 356, height: 3)

        XCTAssertEqual(metrics.hits(in: band), [])
    }

    /// A band drawn down one column takes that column and nothing else — which is the
    /// case a naive bounding-box-of-first-and-last-cell implementation gets wrong.
    func testAColumnBandTakesOnlyThatColumn() {
        let metrics = ImageGridMetrics(width: 356, count: 9)
        let band = CGRect(
            x: metrics.frame(of: 1).minX + 2, y: 0,
            width: metrics.cellWidth - 4, height: metrics.totalHeight
        )

        XCTAssertEqual(metrics.hits(in: band), [1, 4, 7])
    }

    func testTheBandNeverReturnsACellPastTheEndOfTheRun() {
        // Seven pictures is two full lines and a stub; the ninth slot does not exist.
        let metrics = ImageGridMetrics(width: 356, count: 7)
        let full = CGRect(x: 0, y: 0, width: 356, height: metrics.totalHeight)

        XCTAssertEqual(metrics.hits(in: full), Array(0..<7))
    }

    // MARK: - A rubber band across two sheets

    /// Two sheets, stacked the way the list stacks them.
    private func stackedSheets(
        first: Int, second: Int, width: CGFloat = 356, gap: CGFloat = 6
    ) -> [ClipSheetRegistration] {
        let topMetrics = ImageGridMetrics(width: width, count: first)
        let bottomMetrics = ImageGridMetrics(width: width, count: second)
        let top = ClipSheetRegistration(
            range: 0..<first,
            frame: CGRect(x: 0, y: 0, width: width, height: topMetrics.totalHeight),
            metrics: topMetrics
        )
        let bottom = ClipSheetRegistration(
            range: first..<(first + second),
            frame: CGRect(
                x: 0, y: topMetrics.totalHeight + gap,
                width: width, height: bottomMetrics.totalHeight
            ),
            metrics: bottomMetrics
        )
        return [top, bottom]
    }

    /// The regression the cap introduced: a long run of pictures is several sheets, each
    /// with a marquee view of its own, and a mouse sequence belongs to whichever view
    /// took the press. Resolved per sheet, a band dragged past the seam selected nothing
    /// on the far side of it.
    func testABandDraggedAcrossTheSeamSelectsCellsInBothSheets() {
        let sheets = stackedSheets(first: 12, second: 6)
        let band = CGRect(
            x: 0, y: sheets[0].metrics.cellHeight * 3,
            width: 356,
            height: sheets[0].frame.maxY - sheets[0].metrics.cellHeight * 3
                + sheets[1].metrics.cellHeight
        )

        let hits = ClipMarqueeResolver.hits(in: band, sheets: sheets)

        XCTAssertTrue(hits.contains(9), "the last line of the first sheet")
        XCTAssertTrue(hits.contains(12), "the first line of the second sheet")
        XCTAssertTrue(hits.contains(14))
        XCTAssertEqual(hits, hits.sorted(), "list order, which is the order a batch runs in")
    }

    /// The whole of both sheets is every row, once each.
    func testABandOverEverythingTakesEveryRowExactlyOnce() {
        let sheets = stackedSheets(first: 12, second: 6)
        let everything = CGRect(x: 0, y: 0, width: 356, height: sheets[1].frame.maxY)

        XCTAssertEqual(ClipMarqueeResolver.hits(in: everything, sheets: sheets), Array(0..<18))
    }

    /// A band entirely inside one sheet is still only that sheet's cells — the seam is
    /// invisible, not absent.
    func testABandInsideOneSheetDoesNotReachTheOther() {
        let sheets = stackedSheets(first: 12, second: 6)
        let firstLine = CGRect(
            x: 0, y: 2, width: 356, height: sheets[0].metrics.cellHeight - 4
        )

        XCTAssertEqual(ClipMarqueeResolver.hits(in: firstLine, sheets: sheets), [0, 1, 2])
    }

    /// The gap between two sheets belongs to neither.
    func testABandInTheGapBetweenSheetsSelectsNothing() {
        let sheets = stackedSheets(first: 12, second: 6, gap: 10)
        let gap = CGRect(x: 0, y: sheets[0].frame.maxY + 2, width: 356, height: 5)

        XCTAssertEqual(ClipMarqueeResolver.hits(in: gap, sheets: sheets), [])
    }

    // MARK: - Focus, and what must not take it

    /// `makeFirstResponder` on a field that is already being typed into tears down its
    /// field editor and takes an input method's marked text with it — half a word of
    /// pinyin simply disappears. Two of the three things that ask for focus are not user
    /// actions, so either can land mid-composition.
    func testAFocusRequestNeverInterruptsAComposition() {
        XCTAssertFalse(
            PanelSearchFocus.shouldTakeFocus(
                windowIsVisible: true, alreadyEditing: true, composing: true
            )
        )
        XCTAssertFalse(
            PanelSearchFocus.shouldTakeFocus(
                windowIsVisible: true, alreadyEditing: false, composing: true
            )
        )
    }

    /// Nor does it steal the keyboard for a window that is not on screen — which is
    /// exactly what prewarming builds.
    func testAFocusRequestIsIgnoredWhileTheWindowIsNotOnScreen() {
        XCTAssertFalse(
            PanelSearchFocus.shouldTakeFocus(
                windowIsVisible: false, alreadyEditing: false, composing: false
            )
        )
    }

    /// And the case it exists for: the panel is up, the field is not being typed into.
    func testAFocusRequestIsHonouredWhenThereIsSomethingToFocus() {
        XCTAssertTrue(
            PanelSearchFocus.shouldTakeFocus(
                windowIsVisible: true, alreadyEditing: false, composing: false
            )
        )
        XCTAssertFalse(
            PanelSearchFocus.shouldTakeFocus(
                windowIsVisible: true, alreadyEditing: true, composing: false
            ),
            "a field that already has the keyboard does not need it installed again"
        )
    }

    // MARK: - The pill row's own arithmetic

    /// This replaced a `ViewThatFits`, which was the single most expensive thing in the
    /// panel — so the replacement has to give the same answers, and now it can be asked
    /// without rendering anything.
    private var fullCounts: [PanelFilter: Int] {
        [.all: 314, .pinned: 12, .queue: 3, .text: 117, .url: 14, .image: 23, .files: 9]
    }

    func testTheStandardPanelKeepsEveryLabelAndEveryCount() {
        // 400pt panel, less its padding and the badges after the spacer.
        let density = PanelPillLayout.fitted(
            available: 400 - 42, counts: fullCounts, selected: .all
        )
        XCTAssertNotNil(density.countSize, "the standard panel has room for the numbers")
        XCTAssertLessThanOrEqual(
            PanelPillLayout.rowWidth(counts: fullCounts, selected: .all, density: density),
            400 - 42
        )
    }

    /// The failure this is really about: a row that does not fit does not get to cut a
    /// label in half. It gives up the counts first, and only then gives up.
    func testTheCountsAreWhatGivesWayFirst() {
        let wide = PanelPillLayout.fitted(available: 600, counts: fullCounts, selected: .all)
        let narrow = PanelPillLayout.fitted(available: 240, counts: fullCounts, selected: .all)

        XCTAssertNotNil(wide.countSize)
        XCTAssertNil(narrow.countSize, "a narrow row drops the numbers rather than the labels")
    }

    /// A history large enough to put four digits on every pill still fits *somehow* —
    /// the last density is the answer of last resort, and it is the one without counts.
    func testAThousandEntryHistoryStillPicksARowThatFits() {
        let crowded = Dictionary(
            uniqueKeysWithValues: PanelFilter.allCases.map { ($0, 1000) }
        )
        for available in stride(from: 200.0, through: 460.0, by: 20.0) {
            let density = PanelPillLayout.fitted(
                available: available, counts: crowded, selected: .all
            )
            let width = PanelPillLayout.rowWidth(
                counts: crowded, selected: .all, density: density
            )
            // Either it fits, or every density was too wide and we are on the last one.
            XCTAssertTrue(
                width <= available || density == PanelPillLayout.densities.last,
                "at \(available)pt the row picked a density that neither fits nor is the last"
            )
        }
    }

    /// The selected pill is drawn semibold, which is wider — measured, not assumed, or
    /// the row would reflow every time the selection moved between pills.
    func testTheSelectedPillIsMeasuredAtTheWeightItIsDrawn() {
        let density = PanelPillLayout.densities[0]
        let plain = PanelPillLayout.pillWidth(.text, count: 0, selected: false, density: density)
        let bold = PanelPillLayout.pillWidth(.text, count: 0, selected: true, density: density)
        XCTAssertGreaterThanOrEqual(bold, plain)
    }

    func testMeasuredWidthsAreCachedAndStable() {
        let first = PanelTextWidth.width("全部", size: 11, weight: .regular)
        let second = PanelTextWidth.width("全部", size: 11, weight: .regular)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first, 0)
        XCTAssertNotEqual(first, PanelTextWidth.width("全部", size: 22, weight: .regular))
    }

    // MARK: - Row presentation

    private func urlRecord(_ preview: String) -> ClipRecord {
        let id = UUID()
        return ClipRecord(
            id: id, createdAt: Date(), kind: .url, preview: preview,
            digest: "present-\(id.uuidString)", byteSize: preview.utf8.count,
            sourceBundleID: "com.apple.Safari", sourceName: "Safari"
        )
    }

    private func fileRecord(_ preview: String, count: Int) -> ClipRecord {
        let id = UUID()
        return ClipRecord(
            id: id, createdAt: Date(), kind: .files, preview: preview,
            digest: "present-\(id.uuidString)", byteSize: preview.utf8.count,
            sourceBundleID: "com.apple.finder", sourceName: "访达", fileCount: count
        )
    }

    /// A link row shows everything *after* the host, because the chip at the other end
    /// of the row is already saying the host.
    func testALinkIsTakenApartOnceIntoItsHostItsPathAndItsLetter() {
        let presentation = RowPresentation.make(
            urlRecord("https://www.example.com/a/b?c=d"), now: nil
        )

        XCTAssertEqual(presentation.linkHost, "example.com")
        XCTAssertEqual(presentation.displayTitle, "/a/b?c=d")
        XCTAssertEqual(presentation.faviconLetter, "E")
    }

    /// A bare domain has nothing after the host, so it has to keep showing the domain.
    func testABareDomainKeepsShowingItself() {
        let presentation = RowPresentation.make(urlRecord("https://example.com/"), now: nil)

        XCTAssertEqual(presentation.linkHost, "example.com")
        XCTAssertEqual(presentation.displayTitle, "https://example.com/")
    }

    func testAPercentEncodedPathIsReadableAgain() {
        let presentation = RowPresentation.make(
            urlRecord("https://example.com/%E4%B8%AD%E6%96%87"), now: nil
        )

        XCTAssertEqual(presentation.displayTitle, "/中文")
    }

    func testAFileRowIsNamedByItsOwnFileAndPlatedByItsExtension() {
        let presentation = RowPresentation.make(
            fileRecord("/Users/me/素材/封面.PSD", count: 1), now: nil
        )

        XCTAssertEqual(presentation.displayTitle, "封面.PSD")
        XCTAssertEqual(presentation.fileName, "封面.PSD")
        XCTAssertEqual(presentation.fileFolder, "素材")
        XCTAssertEqual(presentation.fileExtension, "PSD")
    }

    func testSeveralFilesAreCountedInTheNameAndNotInThePlate() {
        let presentation = RowPresentation.make(
            fileRecord("/tmp/a.zip\n/tmp/b.zip\n/tmp/c.zip", count: 3), now: nil
        )

        XCTAssertEqual(presentation.displayTitle, "a.zip 等 3 个")
        XCTAssertEqual(presentation.fileExtension, "ZIP")
    }

    /// An extensionless file has no plate to draw, so the plate counts instead.
    func testAFileWithNoExtensionFallsBackToACountOrToFILE() {
        XCTAssertEqual(
            RowPresentation.make(fileRecord("/tmp/README", count: 1), now: nil).fileExtension,
            "FILE"
        )
        XCTAssertEqual(
            RowPresentation.make(fileRecord("/tmp/README\n/tmp/LICENSE", count: 2), now: nil)
                .fileExtension,
            "2"
        )
    }

    /// The parts VoiceOver reads that do not depend on the row's state: what kind of
    /// thing it is, what it says, and where it came from — in that order.
    func testTheSpokenPrefixIsTheKindTheContentAndTheSource() {
        let presentation = RowPresentation.make(urlRecord("https://example.com/a"), now: nil)

        XCTAssertEqual(
            presentation.spokenPrefix, "\(ClipKind.url.label)，https://example.com/a，Safari"
        )
    }

    /// The one derived value with a clock in it. Nil where nobody is listening, which is
    /// what keeps a thirty-second timer from rebuilding the whole list.
    func testTheSpokenAgeIsOnlyWorkedOutWhenItIsAskedFor() {
        let record = urlRecord("https://example.com/a")
        // Measured from the record's own instant: anything else is measuring how long
        // the test itself took to get here.
        let anHourOn = record.createdAt.addingTimeInterval(3600)

        XCTAssertNil(RowPresentation.make(record, now: nil).spokenTime)
        XCTAssertEqual(RowPresentation.make(record, now: anHourOn).spokenTime, "1 小时前")
    }

    /// The digest is what says a cached presentation is still right — an entry rewritten
    /// in the editor keeps its id and rewrites its digest along with its text.
    func testThePresentationCarriesTheDigestItWasDerivedFrom() {
        let record = urlRecord("https://example.com/a")
        XCTAssertEqual(RowPresentation.make(record, now: nil).digest, record.digest)
    }

    // MARK: - Appearance

    func testTheDarkAndLightFacesAreActuallyDifferentFaces() {
        XCTAssertTrue(ClipPanelTheme.resolved(dark: true).dark)
        XCTAssertFalse(ClipPanelTheme.resolved(dark: false).dark)
        XCTAssertNotEqual(ClipPanelTheme.darkTheme, ClipPanelTheme.lightTheme)
        XCTAssertNotEqual(ClipPanelTheme.darkTheme.material, ClipPanelTheme.lightTheme.material)
    }

    /// "Reduce transparency" asks for a panel that is not a window onto the desktop.
    func testReducingTransparencyTakesTheGlassAway() {
        for dark in [true, false] {
            let theme = ClipPanelTheme.resolved(dark: dark, reduceTransparency: true)
            XCTAssertTrue(theme.opaque)
            XCTAssertEqual(theme.material, .windowBackground)
            XCTAssertEqual(
                Self.components(theme.panelTint).alpha, 1, accuracy: 0.001,
                "the tint is the whole of the panel's colour once the blur is gone"
            )
        }
    }

    /// The point of the setting, as a number. `text3` is the panel's faintest colour —
    /// captions, band headers, the ⌘n caps — and at its ordinary weight it is
    /// deliberately below AA. Under "increase contrast" it has to clear it.
    func testIncreasedContrastLiftsTheFaintestTextClearOfWCAGAA() {
        for dark in [true, false] {
            let theme = ClipPanelTheme.resolved(dark: dark, increaseContrast: true)
            let ratio = Self.contrast(theme.text3, over: theme.panelTint, dark: dark)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(dark ? "dark" : "light") high-contrast text3 is only \(ratio):1 on the panel"
            )
        }
    }

    func testIncreasedContrastAlsoThickensEveryHairline() {
        XCTAssertEqual(ClipPanelTheme.resolved(dark: true).borderWidth, 1)
        XCTAssertEqual(ClipPanelTheme.resolved(dark: true, increaseContrast: true).borderWidth, 2)
        XCTAssertEqual(ClipPanelTheme.resolved(dark: false, increaseContrast: true).borderWidth, 2)
    }

    // MARK: Contrast arithmetic

    /// WCAG 2.1's contrast ratio, over the panel's own ground.
    ///
    /// Both colours can be translucent — the tint is laid over a blur, the text over the
    /// tint — so each is flattened onto what is behind it before its luminance is taken.
    /// What is behind the panel is unknowable, so the ground is the extreme that makes
    /// the ratio worst for the face in question: black under the dark panel, white under
    /// the light one.
    private static func contrast(_ foreground: Color, over tint: Color, dark: Bool) -> Double {
        let ground: Double = dark ? 0 : 1
        let panel = composite(components(tint), over: (ground, ground, ground))
        let text = composite(components(foreground), over: panel)
        let light = max(luminance(text), luminance(panel))
        let shade = min(luminance(text), luminance(panel))
        return (light + 0.05) / (shade + 0.05)
    }

    private static func components(
        _ color: Color
    ) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0, 0, 1) }
        return (
            Double(srgb.redComponent), Double(srgb.greenComponent),
            Double(srgb.blueComponent), Double(srgb.alphaComponent)
        )
    }

    private static func composite(
        _ colour: (red: Double, green: Double, blue: Double, alpha: Double),
        over ground: (Double, Double, Double)
    ) -> (Double, Double, Double) {
        (
            colour.red * colour.alpha + ground.0 * (1 - colour.alpha),
            colour.green * colour.alpha + ground.1 * (1 - colour.alpha),
            colour.blue * colour.alpha + ground.2 * (1 - colour.alpha)
        )
    }

    private static func luminance(_ colour: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(colour.0) + 0.7152 * channel(colour.1)
            + 0.0722 * channel(colour.2)
    }
}
