import AppKit
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

    // MARK: - Appearance

    func testTheDarkAndLightFacesAreActuallyDifferentFaces() {
        XCTAssertTrue(ClipPanelTheme.resolved(dark: true).dark)
        XCTAssertFalse(ClipPanelTheme.resolved(dark: false).dark)
        XCTAssertNotEqual(ClipPanelTheme.darkTheme, ClipPanelTheme.lightTheme)
        XCTAssertNotEqual(ClipPanelTheme.darkTheme.material, ClipPanelTheme.lightTheme.material)
    }
}
