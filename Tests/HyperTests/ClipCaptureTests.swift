import AppKit
import CryptoKit
import XCTest

@testable import Hyper

/// Capture decides three things at once: whether to record at all, what kind of thing was
/// copied, and what the row will say. Every test here goes through a private, uniquely
/// named pasteboard, so nothing touches the system clipboard.
final class ClipCaptureTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    /// A real AppKit lazy provider, rather than a fake capture abstraction. This lets
    /// the tests prove which representations `NSPasteboardItem.data(forType:)` actually
    /// asks the source application to materialise, and in what order.
    private final class TrackingDataProvider: NSObject, NSPasteboardItemDataProvider {
        let dataByType: [String: Data]
        let delaysByType: [String: TimeInterval]
        private(set) var requestedTypes: [String] = []

        init(dataByType: [String: Data], delaysByType: [String: TimeInterval] = [:]) {
            self.dataByType = dataByType
            self.delaysByType = delaysByType
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            requestedTypes.append(type.rawValue)
            if let delay = delaysByType[type.rawValue] { Thread.sleep(forTimeInterval: delay) }
            if let data = dataByType[type.rawValue] { item.setData(data, forType: type) }
        }
    }

    override func tearDownWithError() throws {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards.removeAll()
    }

    /// A private pasteboard holding one item, built by `configure`.
    private func makePasteboard(_ configure: (NSPasteboardItem) -> Void) -> NSPasteboard {
        makePasteboard(items: 1) { _, item in configure(item) }
    }

    private func makePasteboard(items: Int, _ configure: (Int, NSPasteboardItem) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hyper-tests-\(UUID().uuidString)"))
        pasteboards.append(pasteboard)
        pasteboard.clearContents()
        var written: [NSPasteboardItem] = []
        for index in 0..<items {
            let item = NSPasteboardItem()
            configure(index, item)
            written.append(item)
        }
        pasteboard.writeObjects(written)
        return pasteboard
    }

    private struct UnexpectedlyIgnored: Error { let reason: String }

    private func capture(
        _ pasteboard: NSPasteboard, options: ClipCapture.Options = ClipCapture.Options()
    ) throws -> (payload: ClipPayload, kind: ClipKind, reduction: ClipCapture.Reduction) {
        switch ClipCapture.read(pasteboard, options: options) {
        case .captured(let payload, let kind, let reduction):
            return (payload, kind, reduction)
        case .ignored(let reason):
            XCTFail("expected a capture, got ignored: \(reason)")
            throw UnexpectedlyIgnored(reason: reason)
        }
    }

    private func capture(
        items: [NSPasteboardItem], options: ClipCapture.Options = ClipCapture.Options()
    ) throws -> (payload: ClipPayload, kind: ClipKind, reduction: ClipCapture.Reduction) {
        switch ClipCapture.read(items: items, options: options) {
        case .captured(let payload, let kind, let reduction):
            return (payload, kind, reduction)
        case .ignored(let reason):
            XCTFail("expected a capture, got ignored: \(reason)")
            throw UnexpectedlyIgnored(reason: reason)
        }
    }

    private func lazyItem(
        _ dataByType: [String: Data], delaysByType: [String: TimeInterval] = [:]
    ) -> (NSPasteboardItem, TrackingDataProvider) {
        let item = NSPasteboardItem()
        let provider = TrackingDataProvider(dataByType: dataByType, delaysByType: delaysByType)
        item.setDataProvider(
            provider,
            forTypes: dataByType.keys.sorted(by: >).map { NSPasteboard.PasteboardType($0) }
        )
        return (item, provider)
    }

    private func ignoredReason(_ pasteboard: NSPasteboard, options: ClipCapture.Options) -> String? {
        if case .ignored(let reason) = ClipCapture.read(pasteboard, options: options) { return reason }
        return nil
    }

    private func assertMetadataOnly(
        _ payload: ClipPayload, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(payload.count, 1, file: file, line: line)
        XCTAssertEqual(
            payload.first?.keys.sorted(), [ClipCapture.oversizedMetadataType],
            file: file, line: line
        )
        XCTAssertLessThan(ClipPayloadCoder.byteSize(payload), 128, file: file, line: line)
        XCTAssertNil(ClipCapture.plainText(from: payload), file: file, line: line)
        XCTAssertNil(ClipCapture.image(from: payload), file: file, line: line)
    }

    private func pngData(width: Int = 4, height: Int = 3) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func colorData(_ color: NSColor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
    }

    // MARK: - Classification

    func testPlainTextClassifiesAsText() throws {
        let result = try capture(makePasteboard { $0.setString("hello world", forType: .string) })
        XCTAssertEqual(result.kind, .text)
        XCTAssertEqual(ClipCapture.plainText(from: result.payload), "hello world")
        XCTAssertEqual(result.reduction.byteSize, 11)
        XCTAssertFalse(result.reduction.oversized)
    }

    func testSingleWordWithAKnownSchemeClassifiesAsURL() throws {
        for link in ["https://example.com/a?b=c", "http://example.com", "mailto:a@example.com"] {
            let result = try capture(makePasteboard { $0.setString(link, forType: .string) })
            XCTAssertEqual(result.kind, .url, "\(link) should read as a link")
        }
    }

    func testTextThatOnlyLooksLikeALinkStaysText() throws {
        for notALink in ["example.com", "see https://example.com for details", "a b c"] {
            let result = try capture(makePasteboard { $0.setString(notALink, forType: .string) })
            XCTAssertEqual(result.kind, .text, "\(notALink) should not read as a link")
        }
    }

    func testStyledTextClassifiesAsRichText() throws {
        let attributed = NSAttributedString(string: "styled")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let result = try capture(makePasteboard {
            $0.setString("styled", forType: .string)
            $0.setData(rtf, forType: .rtf)
        })
        XCTAssertEqual(result.kind, .richText)
        XCTAssertEqual(ClipCapture.plainText(from: result.payload), "styled")
        XCTAssertEqual(result.payload.first?[NSPasteboard.PasteboardType.rtf.rawValue], rtf)
    }

    func testFileURLClassifiesAsFiles() throws {
        let result = try capture(makePasteboard {
            $0.setString("file:///tmp/report.pdf", forType: NSPasteboard.PasteboardType("public.file-url"))
        })
        XCTAssertEqual(result.kind, .files)
        XCTAssertNotNil(result.payload.first?["public.file-url"])
        XCTAssertEqual(ClipCapture.fileURLs(from: result.payload).map(\.lastPathComponent), ["report.pdf"])
    }

    func testImageClassifiesAsImage() throws {
        let png = try pngData()
        let result = try capture(makePasteboard { $0.setData(png, forType: .png) })
        XCTAssertEqual(result.kind, .image)
        let image = try XCTUnwrap(ClipCapture.image(from: result.payload))
        XCTAssertEqual(image.representationPixelSize.width, 4)
        XCTAssertEqual(image.representationPixelSize.height, 3)
    }

    func testPNGRemainsCompatibleWithoutReadingItsRedundantTIFF() throws {
        let png = try pngData()
        let pngType = NSPasteboard.PasteboardType.png.rawValue
        let tiffType = NSPasteboard.PasteboardType.tiff.rawValue
        let (item, provider) = lazyItem([
            pngType: png,
            tiffType: Data(repeating: 9, count: png.count * 20),
        ])

        let result = try capture(items: [item])

        XCTAssertEqual(result.kind, .image)
        XCTAssertEqual(result.payload.first?[pngType], png)
        XCTAssertNil(result.payload.first?[tiffType])
        XCTAssertEqual(provider.requestedTypes, [pngType])
    }

    func testColorClassifiesAsColor() throws {
        let data = try colorData(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let result = try capture(makePasteboard { $0.setData(data, forType: .color) })
        XCTAssertEqual(result.kind, .color)
        XCTAssertEqual(ClipCapture.colorHex(from: result.payload), "#FF0000")
    }

    func testFilesWinOverImagesWhenBothAreOffered() throws {
        // Dragging a picture out of Finder puts both on the pasteboard; the file is the
        // thing that was copied.
        let png = try pngData()
        let result = try capture(makePasteboard {
            $0.setString("file:///tmp/photo.png", forType: NSPasteboard.PasteboardType("public.file-url"))
            $0.setData(png, forType: .png)
        })
        XCTAssertEqual(result.kind, .files)
    }

    // MARK: - Skipping

    func testConcealedContentIsNeverRecorded() {
        for type in ClipCapture.concealedTypes {
            let pasteboard = makePasteboard {
                $0.setString("hunter2", forType: .string)
                $0.setData(Data([1]), forType: NSPasteboard.PasteboardType(type))
            }
            XCTAssertEqual(ignoredReason(pasteboard, options: ClipCapture.Options()), "concealed",
                           "\(type) should suppress the capture")
        }
    }

    func testConcealedSkipCanBeTurnedOff() throws {
        let pasteboard = makePasteboard {
            $0.setString("hunter2", forType: .string)
            $0.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        var options = ClipCapture.Options()
        options.skipConcealed = false
        let result = try capture(pasteboard, options: options)
        XCTAssertEqual(result.kind, .text)
        // The marker itself is never written back out with the payload.
        XCTAssertNil(result.payload.first?["org.nspasteboard.ConcealedType"])
    }

    func testTransientContentIsSkipped() {
        let pasteboard = makePasteboard {
            $0.setString("temporary", forType: .string)
            $0.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        XCTAssertEqual(ignoredReason(pasteboard, options: ClipCapture.Options()), "transient")

        var options = ClipCapture.Options()
        options.skipTransient = false
        XCTAssertNil(ignoredReason(pasteboard, options: options))
    }

    func testImagesCanBeDisabled() throws {
        let png = try pngData()
        let pasteboard = makePasteboard { $0.setData(png, forType: .png) }
        var options = ClipCapture.Options()
        options.recordImages = false
        XCTAssertEqual(ignoredReason(pasteboard, options: options), "images disabled")
    }

    func testEmptyPasteboardIsIgnored() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hyper-tests-\(UUID().uuidString)"))
        pasteboards.append(pasteboard)
        pasteboard.clearContents()
        XCTAssertEqual(ignoredReason(pasteboard, options: ClipCapture.Options()), "empty")
    }

    func testOversizedPayloadIsFlaggedAndStrippedBeforeDownstreamWork() throws {
        let pasteboard = makePasteboard { $0.setString(String(repeating: "x", count: 4096), forType: .string) }
        var options = ClipCapture.Options()
        options.maxItemBytes = 1024
        let result = try capture(pasteboard, options: options)
        XCTAssertTrue(result.reduction.oversized)
        XCTAssertEqual(result.reduction.byteSize, 4096)
        assertMetadataOnly(result.payload)
        XCTAssertNil(result.payload.first?[NSPasteboard.PasteboardType.string.rawValue])
    }

    // MARK: - Budgeted lazy providers

    func testHighValuePublicTypesAreReadBeforePrivateRepresentations() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let html = NSPasteboard.PasteboardType.html.rawValue
        let privateType = "com.example.editor.private-document"
        let (item, provider) = lazyItem([
            privateType: Data(repeating: 3, count: 32),
            html: Data(repeating: 2, count: 32),
            plain: Data("hello".utf8),
        ])
        var options = ClipCapture.Options()
        options.maxItemBytes = 16

        let result = try capture(items: [item], options: options)

        XCTAssertFalse(result.reduction.oversized)
        XCTAssertTrue(result.reduction.truncated)
        XCTAssertEqual(provider.requestedTypes, [plain, html])
        XCTAssertFalse(provider.requestedTypes.contains(privateType))
        XCTAssertEqual(ClipCapture.plainText(from: result.payload), "hello")
        XCTAssertNil(result.payload.first?[html])
        XCTAssertNil(result.payload.first?[privateType])
    }

    func testAggregateBudgetStopsBeforeAnyRemainingItemOrTypeIsRead() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let privateType = "com.example.never-read"
        let (first, firstProvider) = lazyItem([plain: Data(repeating: 1, count: 600)])
        let (second, secondProvider) = lazyItem([plain: Data(repeating: 2, count: 600)])
        let (third, thirdProvider) = lazyItem([privateType: Data(repeating: 3, count: 1)])
        var options = ClipCapture.Options()
        options.maxItemBytes = 1_000
        options.maxTypeBytes = 1_000

        let result = try capture(items: [first, second, third], options: options)

        XCTAssertFalse(result.reduction.oversized)
        XCTAssertTrue(result.reduction.truncated)
        XCTAssertEqual(result.reduction.byteSize, 600)
        XCTAssertEqual(result.reduction.observedByteSize, 1_200)
        XCTAssertEqual(firstProvider.requestedTypes, [plain])
        XCTAssertEqual(secondProvider.requestedTypes, [plain])
        XCTAssertTrue(thirdProvider.requestedTypes.isEmpty)
        XCTAssertFalse(result.reduction.byteSizeIsLowerBound)
        XCTAssertEqual(result.payload.count, 1)
        XCTAssertEqual(result.payload.first?[plain], Data(repeating: 1, count: 600))
    }

    func testSingleRepresentationBudgetCanBeStricterThanAggregateBudget() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let (item, provider) = lazyItem([plain: Data(repeating: 1, count: 600)])
        var options = ClipCapture.Options()
        options.maxItemBytes = 4_096
        options.maxTypeBytes = 512

        let result = try capture(items: [item], options: options)

        XCTAssertTrue(result.reduction.oversized)
        XCTAssertEqual(result.reduction.byteSize, 600)
        XCTAssertFalse(result.reduction.byteSizeIsLowerBound)
        XCTAssertEqual(provider.requestedTypes, [plain])
        assertMetadataOnly(result.payload)
    }

    func testExhaustedAggregateBudgetStopsBeforeTheNextProvider() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let privateType = "com.example.must-not-materialise"
        let (item, provider) = lazyItem([
            plain: Data(repeating: 1, count: 512),
            privateType: Data(repeating: 2, count: 1),
        ])
        var options = ClipCapture.Options()
        options.maxItemBytes = 512

        let result = try capture(items: [item], options: options)

        XCTAssertFalse(result.reduction.oversized)
        XCTAssertFalse(result.reduction.truncated)
        XCTAssertEqual(result.reduction.byteSize, 512)
        XCTAssertEqual(provider.requestedTypes, [plain])
        XCTAssertEqual(result.payload.first?[plain], Data(repeating: 1, count: 512))
        XCTAssertNil(result.payload.first?[privateType])
    }

    func testOversizedPrivateRepresentationKeepsPasteablePublicText() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let privateType = "com.example.editor.twenty-one-megabyte-document"
        let (item, provider) = lazyItem([
            plain: Data("hello".utf8),
            privateType: Data(repeating: 7, count: 21 * 1024 * 1024),
        ])
        var options = ClipCapture.Options()
        options.maxItemBytes = 20 * 1024 * 1024

        let result = try capture(items: [item], options: options)

        XCTAssertFalse(result.reduction.oversized)
        XCTAssertFalse(result.reduction.truncated)
        XCTAssertEqual(result.reduction.byteSize, 5)
        XCTAssertEqual(result.reduction.observedByteSize, 5)
        XCTAssertEqual(provider.requestedTypes, [plain])
        XCTAssertEqual(result.payload, [[plain: Data("hello".utf8)]])
        XCTAssertEqual(ClipCapture.plainText(from: result.payload), "hello")
    }

    func testOversizedPrivateRepresentationKeepsPasteableRTFAndPNG() throws {
        let privateType = "com.example.editor.oversized-private"
        let rtfData = Data("{\\rtf1 retained}".utf8)
        let (rtfItem, rtfProvider) = lazyItem([
            NSPasteboard.PasteboardType.rtf.rawValue: rtfData,
            privateType: Data(repeating: 8, count: 2_048),
        ])
        var rtfOptions = ClipCapture.Options()
        rtfOptions.maxItemBytes = 1_024
        let rtf = try capture(items: [rtfItem], options: rtfOptions)
        XCTAssertFalse(rtf.reduction.truncated)
        XCTAssertFalse(rtf.reduction.oversized)
        XCTAssertEqual(rtf.kind, .richText)
        XCTAssertEqual(rtf.payload, [[NSPasteboard.PasteboardType.rtf.rawValue: rtfData]])
        XCTAssertEqual(rtfProvider.requestedTypes, [NSPasteboard.PasteboardType.rtf.rawValue])

        let pngData = try pngData()
        let (pngItem, pngProvider) = lazyItem([
            NSPasteboard.PasteboardType.png.rawValue: pngData,
            privateType: Data(repeating: 9, count: pngData.count + 1_024),
        ])
        var pngOptions = ClipCapture.Options()
        pngOptions.maxItemBytes = pngData.count + 512
        let png = try capture(items: [pngItem], options: pngOptions)
        XCTAssertFalse(png.reduction.truncated)
        XCTAssertFalse(png.reduction.oversized)
        XCTAssertEqual(png.kind, .image)
        XCTAssertEqual(png.payload, [[NSPasteboard.PasteboardType.png.rawValue: pngData]])
        XCTAssertEqual(pngProvider.requestedTypes, [NSPasteboard.PasteboardType.png.rawValue])
    }

    func testProviderRequestBudgetBoundsAPathologicalMultiTypeItem() throws {
        let types = Dictionary(uniqueKeysWithValues: (0..<20).map {
            ("com.example.private-\(String(format: "%02d", $0))", Data([UInt8($0)]))
        })
        let (item, provider) = lazyItem(types)
        var options = ClipCapture.Options()
        options.maxTypeReads = 3

        guard case .ignored(let reason) = ClipCapture.read(items: [item], options: options) else {
            XCTFail("an unknown-private-only item must be ignored")
            return
        }
        XCTAssertEqual(reason, "no readable types")
        XCTAssertTrue(provider.requestedTypes.isEmpty)
    }

    func testEarlyBudgetStopDoesNotInvokeADeferredLowPriorityProvider() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let slowPrivateType = "com.example.slow-private-representation"
        let (item, provider) = lazyItem(
            [
                plain: Data(repeating: 1, count: 2_048),
                slowPrivateType: Data([2]),
            ],
            delaysByType: [slowPrivateType: 0.2]
        )
        var options = ClipCapture.Options()
        options.maxItemBytes = 128

        let started = Date()
        let result = try capture(items: [item], options: options)

        XCTAssertTrue(result.reduction.oversized)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        XCTAssertEqual(provider.requestedTypes, [plain])
    }

    func testSingleProviderSizeIsKnownOnlyAfterAppKitMaterialisesItsData() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let (item, provider) = lazyItem([plain: Data(repeating: 1, count: 2_048)])
        var options = ClipCapture.Options()
        options.maxItemBytes = 32

        let result = try capture(items: [item], options: options)

        // NSPasteboardItem exposes no byte-count probe. The capture can discard this
        // representation immediately after data(forType:) returns, but the provider's
        // one allocation has already happened. This test keeps that system limit honest.
        XCTAssertEqual(provider.requestedTypes, [plain])
        XCTAssertEqual(result.reduction.byteSize, 2_048)
        assertMetadataOnly(result.payload)
    }

    func testStrippedOversizedRowsDoNotAllCollapseToTheSameDigest() throws {
        var options = ClipCapture.Options()
        options.maxItemBytes = 32
        let first = try capture(makePasteboard {
            $0.setString(String(repeating: "a", count: 2_048), forType: .string)
        }, options: options)
        let second = try capture(makePasteboard {
            $0.setString(String(repeating: "b", count: 2_048), forType: .string)
        }, options: options)
        let firstAgain = try capture(makePasteboard {
            $0.setString(String(repeating: "a", count: 2_048), forType: .string)
        }, options: options)

        assertMetadataOnly(first.payload)
        assertMetadataOnly(second.payload)
        assertMetadataOnly(firstAgain.payload)
        XCTAssertEqual(
            ClipPayloadCoder.digest(first.payload), ClipPayloadCoder.digest(firstAgain.payload),
            "the same oversized source must still bump its existing row"
        )
        XCTAssertNotEqual(ClipPayloadCoder.digest(first.payload), ClipPayloadCoder.digest(second.payload))
    }

    func testRichBytesRemainOpaqueButMalformedImagesFailClosed() throws {
        let invalidRTF = Data("not actually rtf".utf8)
        let rtf = try capture(makePasteboard {
            $0.setData(invalidRTF, forType: .rtf)
        })
        XCTAssertEqual(rtf.kind, .richText)
        XCTAssertEqual(rtf.payload.first?[NSPasteboard.PasteboardType.rtf.rawValue], invalidRTF)

        let invalidPNG = Data("not actually png".utf8)
        let pasteboard = makePasteboard {
            $0.setData(invalidPNG, forType: .png)
        }
        XCTAssertEqual(
            ignoredReason(pasteboard, options: .init()),
            "invalid or over-budget image"
        )
    }

    func testPurePayloadAnalysisRunsOffMainAfterCapture() throws {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let payload: ClipPayload = [[
            plain: Data("hello".utf8),
            NSPasteboard.PasteboardType.rtf.rawValue: Data("invalid rtf is never parsed here".utf8),
            NSPasteboard.PasteboardType.png.rawValue: Data("invalid png is never decoded here".utf8),
        ]]
        let completed = expectation(description: "background payload analysis")

        ClipCapture.analyzePayloadOffMain(payload) { analysis in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(analysis.digest, ClipPayloadCoder.digest(payload))
            XCTAssertEqual(analysis.byteSize, ClipPayloadCoder.byteSize(payload))
            XCTAssertEqual(analysis.plainText, "hello")
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
    }

    // MARK: - Previews

    func testPreviewCollapsesWhitespace() {
        let payload: ClipPayload = [["public.utf8-plain-text": Data("  line one\n\n\tline two  ".utf8)]]
        XCTAssertEqual(ClipCapture.makePreview(kind: .text, payload: payload), "line one line two")
    }

    func testPreviewIsTruncatedAtFourHundredCharacters() {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(String(repeating: "a", count: 900).utf8)]]
        XCTAssertEqual(ClipCapture.makePreview(kind: .text, payload: payload).count, 400)
    }

    func testPreviewOfWhitespaceOnlyTextSaysSo() {
        let payload: ClipPayload = [["public.utf8-plain-text": Data("   \n\t ".utf8)]]
        XCTAssertEqual(ClipCapture.makePreview(kind: .text, payload: payload), "（空白内容）")
    }

    func testPreviewOfFilesNamesThemOrCountsThem() {
        let one: ClipPayload = [["public.file-url": Data("file:///tmp/a.txt".utf8)]]
        XCTAssertEqual(ClipCapture.makePreview(kind: .files, payload: one), "a.txt")

        let many: ClipPayload = [
            ["public.file-url": Data("file:///tmp/a.txt".utf8)],
            ["public.file-url": Data("file:///tmp/b.txt".utf8)],
        ]
        XCTAssertEqual(ClipCapture.makePreview(kind: .files, payload: many), "a.txt 等 2 个文件")

        XCTAssertEqual(ClipCapture.makePreview(kind: .files, payload: [[:]]), "文件")
    }

    func testPreviewOfAnImageIsALabel() {
        XCTAssertEqual(ClipCapture.makePreview(kind: .image, payload: [[:]]), "图片")
    }

    func testPreviewOfAColorPrefersTheParsedValue() throws {
        let data = try colorData(NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
        let payload: ClipPayload = [[NSPasteboard.PasteboardType.color.rawValue: data]]
        XCTAssertEqual(ClipCapture.makePreview(kind: .color, payload: payload), "#0080FF")
    }

    // MARK: - Multiple items

    func testEveryPasteboardItemBecomesOnePayloadEntry() throws {
        let pasteboard = makePasteboard(items: 3) { index, item in
            item.setString("file:///tmp/f\(index).txt", forType: NSPasteboard.PasteboardType("public.file-url"))
        }
        let result = try capture(pasteboard)
        XCTAssertEqual(result.kind, .files)
        XCTAssertEqual(result.payload.count, 3)
        XCTAssertEqual(
            ClipCapture.fileURLs(from: result.payload).map(\.lastPathComponent).sorted(),
            ["f0.txt", "f1.txt", "f2.txt"]
        )
    }

    // MARK: - Colour parsing

    func testColorHexFallsBackToTheTextBesideTheSwatch() {
        // Some applications write only the notation; the swatch is still worth showing.
        let payload: ClipPayload = [["public.utf8-plain-text": Data("#00ff00".utf8)]]
        XCTAssertEqual(ClipCapture.colorHex(from: payload), "#00FF00")
        XCTAssertNil(ClipCapture.colorHex(from: [["public.utf8-plain-text": Data("not a colour".utf8)]]))
    }

    func testColorValueParsesShortAndLongHex() {
        XCTAssertEqual(ClipColorValue(hex: "#ABC"), ClipColorValue(hex: "#AABBCC"))
        XCTAssertEqual(ClipColorValue(hex: "ff0000")?.hexString, "#FF0000")
        XCTAssertEqual(ClipColorValue(hex: "  #ff0000  ")?.hexString, "#FF0000")
        XCTAssertNil(ClipColorValue(hex: "#GG0000"))
        XCTAssertNil(ClipColorValue(hex: "#ff00"))
        XCTAssertNil(ClipColorValue(hex: ""))
    }

    func testColorValueNotations() throws {
        let red = try XCTUnwrap(ClipColorValue(hex: "#FF0000"))
        XCTAssertEqual(red.rgbString, "rgb(255, 0, 0)")
        XCTAssertEqual(red.hslString, "hsl(0, 100%, 50%)")

        let grey = try XCTUnwrap(ClipColorValue(hex: "#808080"))
        XCTAssertEqual(grey.hslString, "hsl(0, 0%, 50%)", "a grey has no hue and no saturation")

        // Components are clamped rather than allowed to produce a nonsense hex.
        XCTAssertEqual(ClipColorValue(red: 2, green: -1, blue: 0.5).hexString, "#FF0080")
    }

    // MARK: - Payload coding

    func testPayloadRoundTripsThroughAPropertyList() throws {
        let payload: ClipPayload = [["public.utf8-plain-text": Data("hello".utf8)]]
        let data = try XCTUnwrap(ClipPayloadCoder.encode(payload))
        let decoded = try XCTUnwrap(ClipPayloadCoder.decode(data))
        XCTAssertEqual(decoded, payload)
        XCTAssertNil(ClipPayloadCoder.decode(Data("not a plist".utf8)))
    }

    func testDigestIgnoresTypeOrderButNotContent() {
        let a: ClipPayload = [["b": Data([2]), "a": Data([1])]]
        let b: ClipPayload = [["a": Data([1]), "b": Data([2])]]
        XCTAssertEqual(ClipPayloadCoder.digest(a), ClipPayloadCoder.digest(b))

        let different: ClipPayload = [["a": Data([1]), "b": Data([3])]]
        XCTAssertNotEqual(ClipPayloadCoder.digest(a), ClipPayloadCoder.digest(different))

        // Item boundaries are part of the identity: two items are not one concatenation.
        let split: ClipPayload = [["a": Data([1])], ["b": Data([2])]]
        XCTAssertNotEqual(ClipPayloadCoder.digest(a), ClipPayloadCoder.digest(split))
    }

    func testByteSizeSumsEveryTypeOfEveryItem() {
        let payload: ClipPayload = [["a": Data(count: 10), "b": Data(count: 5)], ["c": Data(count: 1)]]
        XCTAssertEqual(ClipPayloadCoder.byteSize(payload), 16)
        XCTAssertEqual(ClipPayloadCoder.byteSize([]), 0)
    }

    // MARK: - Edited text

    func testTextKindFollowsWhatWasTyped() {
        XCTAssertEqual(ClipCapture.textKind(for: "  https://example.com "), .url)
        XCTAssertEqual(ClipCapture.textKind(for: "https://example.com and more"), .text)
        XCTAssertEqual(ClipCapture.textKind(for: ""), .text)
    }

    func testPlainTextOnlyStopsShortOfStyledText() throws {
        let attributed = NSAttributedString(string: "styled")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let payload: ClipPayload = [[NSPasteboard.PasteboardType.rtf.rawValue: rtf]]
        XCTAssertNil(
            ClipCapture.plainTextOnly(from: payload),
            "the background scan must not reach for NSAttributedString"
        )
        XCTAssertEqual(ClipCapture.plainText(from: payload), "styled")
    }

    // MARK: - Content tags

    func testAddressesAndNumbersAreTagged() {
        XCTAssertEqual(ClipCapture.contentTag(for: "  indincys@gmail.com "), .email)
        XCTAssertEqual(ClipCapture.contentTag(for: "a.b+tag@sub.example.co.uk"), .email)
        XCTAssertEqual(ClipCapture.contentTag(for: "+86 138 0013 8000"), .phone)
        XCTAssertEqual(ClipCapture.contentTag(for: "(021) 6543-2100"), .phone)
    }

    func testAddressesOnlyCountWhenTheyAreTheWholeLine() {
        // An address quoted inside a sentence is a sentence; the badge would be
        // describing one word of the row rather than the row.
        XCTAssertNil(ClipCapture.contentTag(for: "有问题请联系 indincys@gmail.com 谢谢"))
        XCTAssertNil(ClipCapture.contentTag(for: "a@b.com\nc@d.com"))
    }

    func testNumbersThatAreNotPhoneNumbersAreLeftAlone() {
        // Too few digits to be a number anyone could call, and a price is not a phone.
        for notAPhone in ["2026", "12345", "128.50", "1-2"] {
            XCTAssertNil(ClipCapture.contentTag(for: notAPhone), "\(notAPhone) is not a phone number")
        }
    }

    func testFilePathsAreTagged() {
        XCTAssertEqual(ClipCapture.contentTag(for: "/usr/local/bin/hyper"), .path)
        XCTAssertEqual(ClipCapture.contentTag(for: "~/.local/share/hyper/clipboard"), .path)
        // A path with a space in it is indistinguishable from a sentence that opens
        // with a slash, so it is given up on rather than guessed at.
        XCTAssertNil(ClipCapture.contentTag(for: "/Users/me/My Documents"))
        XCTAssertNil(ClipCapture.contentTag(for: "relative/path/file.txt"))
    }

    func testJSONIsParsedRatherThanPatternMatched() {
        XCTAssertEqual(ClipCapture.contentTag(for: #"{"name": "hyper", "ok": true}"#), .json)
        XCTAssertEqual(ClipCapture.contentTag(for: "[1, 2, 3]"), .json)
        // Opens like JSON, is not JSON — and nothing else here matches it either.
        XCTAssertNotEqual(ClipCapture.contentTag(for: #"{name: hyper,"#), .json)
    }

    func testCodeNeedsMoreThanOneLineAndOneWord() {
        let swift = """
        func greet(_ name: String) -> String {
            return "hello, \\(name)"
        }
        """
        XCTAssertEqual(ClipCapture.contentTag(for: swift), .code)
        let c = "#include <stdio.h>\nint main(void) { return 0; }"
        XCTAssertEqual(ClipCapture.contentTag(for: c), .code)
        // One line carrying one marker is far more often prose about code than code.
        XCTAssertNil(ClipCapture.contentTag(for: "记得 import 那个模块"))
    }

    func testOrdinaryProseIsNeverTagged() {
        let chinese = """
        今天下午的会议改到了三点，地点在二楼的小会议室。
        麻烦提前十分钟到，我们先过一遍上周留下的问题，
        然后再讨论下一阶段的安排。
        """
        XCTAssertNil(ClipCapture.contentTag(for: chinese))
        let english = """
        The meeting moved to three o'clock, in the small room upstairs.
        Please arrive ten minutes early so that we can go over
        what was left open last week.
        """
        XCTAssertNil(ClipCapture.contentTag(for: english))
        XCTAssertNil(ClipCapture.contentTag(for: "   \n  "))
        XCTAssertNil(ClipCapture.contentTag(for: ""))
    }

    // MARK: - Preview collapsing

    /// Exactly what `makePreview` used to run: one regular expression over the whole
    /// body, a trim, and only then the 400-character cut.
    private func legacyCollapsedPreview(_ raw: String, limit: Int = 400) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(limit))
    }

    private var previewSamples: [String] {
        [
            "",
            " ",
            "     ",
            "hello",
            "  hello   world  ",
            "a\n\nb",
            "\tx\ty\t",
            "line one\r\nline two",
            "   leading only",
            "trailing only   ",
            "\n\n mixed \t\t whitespace \n runs \n\n",
            "中文 内容　测试",  // the middle separator is U+3000
            "换行\n中文\t制表",
            "no\u{00A0}break\u{00A0}space",
            "😀 👍🏽 🇨🇳 hi",
            "emoji\n😀\n\nfamily 👨‍👩‍👧‍👦 end",
            String(repeating: "long   ", count: 2_000),
            String(repeating: "字", count: 1_000),
            String(repeating: "😀", count: 600),
            String(repeating: " ", count: 500) + "after a lot of space",
            "exactly" + String(repeating: " a", count: 400),
        ]
    }

    func testCollapsedPreviewMatchesTheRegexImplementationItReplaced() {
        for sample in previewSamples {
            XCTAssertEqual(
                ClipCapture.collapsedPreview(sample),
                legacyCollapsedPreview(sample),
                "sample: \(sample.debugDescription.prefix(80))"
            )
        }
    }

    func testCollapsedPreviewMatchesTheRegexImplementationAtOtherLimits() {
        for limit in [1, 2, 7, 400, 4_000] {
            for sample in previewSamples {
                XCTAssertEqual(
                    ClipCapture.collapsedPreview(sample, limit: limit),
                    legacyCollapsedPreview(sample, limit: limit),
                    "limit \(limit), sample: \(sample.debugDescription.prefix(80))"
                )
            }
        }
    }

    /// The point of the rewrite: a megabyte-sized copy must not be walked end to end to
    /// produce a 400-character row label.
    func testCollapsedPreviewOfAMegabyteBodyCostsNoMoreThanItsPrefix() {
        let huge = String(repeating: "needle haystack ", count: 65_536)
        XCTAssertGreaterThan(huge.count, 1_000_000)

        let started = ProcessInfo.processInfo.systemUptime
        let preview = ClipCapture.collapsedPreview(huge)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        let legacyStarted = ProcessInfo.processInfo.systemUptime
        let legacy = legacyCollapsedPreview(huge)
        let legacyElapsed = ProcessInfo.processInfo.systemUptime - legacyStarted

        XCTAssertEqual(preview, legacy)
        XCTAssertEqual(preview.count, 400)
        print(String(
            format: "PREVIEW_1MB new=%.3fms regex=%.3fms",
            elapsed * 1_000, legacyElapsed * 1_000
        ))
        XCTAssertLessThan(
            elapsed, 0.010,
            String(format: "preview of a 1MB body took %.3fms", elapsed * 1_000)
        )
    }

    func testMakePreviewStillReportsWhitespaceOnlyBodies() {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(" \n\t ".utf8)]]
        XCTAssertEqual(ClipCapture.makePreview(kind: .text, payload: payload), "（空白内容）")
    }

    // MARK: - Hexadecimal encoding

    func testHexTableProducesExactlyWhatStringFormatDid() {
        let everyByte = Data((0...255).map(UInt8.init))
        XCTAssertEqual(
            ClipHex.string(everyByte),
            everyByte.map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(ClipHex.string(Data()), "")
    }

    func testDigestAndPlaintextHashKeepTheirFormattedSpelling() {
        let payload: ClipPayload = [["public.utf8-plain-text": Data("hex table digest".utf8)]]
        var hasher = SHA256()
        for item in payload {
            for key in item.keys.sorted() {
                hasher.update(data: Data(key.utf8))
                hasher.update(data: item[key] ?? Data())
            }
            hasher.update(data: Data([0x1e]))
        }
        XCTAssertEqual(
            ClipPayloadCoder.digest(payload),
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )

        let bytes = Data("plaintext hash spelling".utf8)
        XCTAssertEqual(
            ClipboardVault.plaintextHash(bytes),
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
    }
    // MARK: - Relative time

    /// `relativeTime` now reuses one `DateFormatter` instead of building one per call.
    /// The output has to be byte-identical to what a freshly built formatter produced,
    /// including across the four relative bands and the absolute fallback.
    func testRelativeTimeMatchesTheFreshFormatterItReplaced() {
        func reference(from date: Date, to now: Date) -> String {
            let seconds = Int(now.timeIntervalSince(date))
            switch seconds {
            case ..<60: return "刚刚"
            case ..<3600: return "\(seconds / 60) 分钟前"
            case ..<86400: return "\(seconds / 3600) 小时前"
            case ..<(86400 * 7): return "\(seconds / 86400) 天前"
            default:
                let formatter = DateFormatter()
                formatter.dateFormat = "M月d日"
                return formatter.string(from: date)
            }
        }

        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let offsets: [TimeInterval] = [
            0, 1, 59, 60, 61, 3_599, 3_600, 7_200, 86_399, 86_400,
            86_400 * 3, 86_400 * 7 - 1, 86_400 * 7, 86_400 * 30,
            86_400 * 200, 86_400 * 400, 86_400 * 1_000,
        ]
        for offset in offsets {
            let date = now.addingTimeInterval(-offset)
            XCTAssertEqual(
                ClipRecord.relativeTime(from: date, to: now),
                reference(from: date, to: now),
                "offset \(offset)s formatted differently once the formatter was cached"
            )
        }

        // The named cases, spelled out, so a changed format string is a failing test and
        // not just a changed reference implementation.
        XCTAssertEqual(ClipRecord.relativeTime(from: now.addingTimeInterval(-30), to: now), "刚刚")
        XCTAssertEqual(
            ClipRecord.relativeTime(from: now.addingTimeInterval(-600), to: now), "10 分钟前"
        )
        XCTAssertEqual(
            ClipRecord.relativeTime(from: now.addingTimeInterval(-7_200), to: now), "2 小时前"
        )
        XCTAssertEqual(
            ClipRecord.relativeTime(from: now.addingTimeInterval(-86_400 * 3), to: now), "3 天前"
        )

        // A reused formatter must not accumulate state between calls.
        let old = now.addingTimeInterval(-86_400 * 90)
        let first = ClipRecord.relativeTime(from: old, to: now)
        _ = ClipRecord.relativeTime(from: now.addingTimeInterval(-86_400 * 365), to: now)
        XCTAssertEqual(ClipRecord.relativeTime(from: old, to: now), first)
    }
}
