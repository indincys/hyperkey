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

    // MARK: - Appearance

    func testTheDarkAndLightFacesAreActuallyDifferentFaces() {
        XCTAssertTrue(ClipPanelTheme.resolved(dark: true).dark)
        XCTAssertFalse(ClipPanelTheme.resolved(dark: false).dark)
        XCTAssertNotEqual(ClipPanelTheme.darkTheme, ClipPanelTheme.lightTheme)
        XCTAssertNotEqual(ClipPanelTheme.darkTheme.material, ClipPanelTheme.lightTheme.material)
    }
}
