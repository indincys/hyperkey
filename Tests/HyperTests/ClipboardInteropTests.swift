import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Hyper

final class ClipboardInteropTests: XCTestCase {
    private final class ProviderProbe {
        let provider = NSItemProvider()
        let progress = Progress(totalUnitCount: 1)
        private(set) var loadCount = 0

        init(type: String, data: Data?, delay: TimeInterval? = 0) {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) {
                [weak self] completion in
                guard let self else { return nil }
                self.loadCount += 1
                if let delay {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        completion(data, data == nil ? NSError(domain: "probe", code: 1) : nil)
                    }
                }
                return self.progress
            }
        }
    }

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = .withUniqueName()
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    private func richFixture(_ text: String = "Bold & safe") throws -> (rtf: Data, html: Data) {
        let value = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
        )
        let range = NSRange(location: 0, length: value.length)
        return (
            try value.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ),
            try value.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
            )
        )
    }

    private func placedTypes() -> [Set<String>] {
        (pasteboard.pasteboardItems ?? []).map { Set($0.types.map(\.rawValue)) }
    }

    private func encodedImage(type: String, width: Int = 16, height: Int = 12) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let image = try XCTUnwrap(bitmap.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, type as CFString, 1, nil
        ), "ImageIO encoder unavailable for \(type)")
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "could not encode \(type)")
        return output as Data
    }

    func testOriginalModeKeepsKnownBrowserAndOfficeFormatsButDropsUnsafePrivateTypes() throws {
        let rich = try richFixture()
        let safariURLs = try PropertyListSerialization.data(
            fromPropertyList: [["https://example.com"], ["Example"]],
            format: .binary,
            options: 0
        )
        let payload: ClipPayload = [[
            UTType.utf8PlainText.identifier: Data("Bold & safe".utf8),
            UTType.rtf.identifier: rich.rtf,
            UTType.html.identifier: rich.html,
            "com.apple.WebKit.custom-pasteboard-data": safariURLs,
            "com.microsoft.ObjectLink": Data([0x4d, 0x53, 0x4f]),
            "com.example.private-unserialised-object": Data([0xde, 0xad]),
            "org.nspasteboard.source": Data("secret source".utf8),
        ]]

        _ = try Paster.place(payload, as: .original, to: pasteboard).get()

        XCTAssertEqual(placedTypes(), [[
            UTType.utf8PlainText.identifier,
            "public.utf16-external-plain-text",
            UTType.rtf.identifier,
            UTType.html.identifier,
            "com.apple.WebKit.custom-pasteboard-data",
            "com.microsoft.ObjectLink",
        ]])
        XCTAssertNil(
            pasteboard.data(forType: NSPasteboard.PasteboardType(
                "com.example.private-unserialised-object"
            ))
        )
        XCTAssertNil(pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")))
    }

    func testPasteAsModesWritePredictableTypeSets() throws {
        let rich = try richFixture("Styled text")
        let payload: ClipPayload = [[
            UTType.utf8PlainText.identifier: Data("Styled text".utf8),
            UTType.rtf.identifier: rich.rtf,
            UTType.html.identifier: rich.html,
        ]]

        let expectations: [(PasteAsMode, Set<String>)] = [
            (
                .richText,
                [
                    UTType.rtf.identifier, UTType.html.identifier, UTType.utf8PlainText.identifier,
                    "public.utf16-external-plain-text",
                ]
            ),
            (
                .rtf,
                [
                    UTType.rtf.identifier, UTType.utf8PlainText.identifier,
                    "public.utf16-external-plain-text",
                ]
            ),
            (.html, [UTType.html.identifier, UTType.utf8PlainText.identifier]),
            (.plainText, [UTType.utf8PlainText.identifier]),
        ]

        for (mode, expected) in expectations {
            pasteboard.clearContents()
            _ = try Paster.place(payload, as: mode, to: pasteboard).get()
            XCTAssertEqual(placedTypes(), [expected], "unexpected representations for \(mode)")
            XCTAssertEqual(pasteboard.string(forType: .string), "Styled text")
        }
    }

    func testGoldFixturesRoundTripWithCorrectRichAndPlainFallbacks() throws {
        let rich = try richFixture("Quarterly résumé")
        let fixtures: [(name: String, payload: ClipPayload, original: Set<String>)] = [
            (
                "Safari",
                [[
                    UTType.html.identifier: rich.html,
                    UTType.utf8PlainText.identifier: Data("Quarterly résumé".utf8),
                    "com.apple.WebKit.custom-pasteboard-data": try PropertyListSerialization.data(
                        fromPropertyList: [["https://example.com"]], format: .binary, options: 0
                    ),
                ]],
                [
                    UTType.html.identifier, UTType.utf8PlainText.identifier,
                    "com.apple.WebKit.custom-pasteboard-data",
                ]
            ),
            (
                "Pages",
                [[
                    UTType.rtf.identifier: rich.rtf,
                    UTType.html.identifier: rich.html,
                    UTType.utf8PlainText.identifier: Data("Quarterly résumé".utf8),
                    "com.apple.iWork.TSPNativeData": Data([0x69, 0x57, 0x6f, 0x72, 0x6b]),
                ]],
                [
                    UTType.rtf.identifier, UTType.html.identifier, UTType.utf8PlainText.identifier,
                    "public.utf16-external-plain-text", "com.apple.iWork.TSPNativeData",
                ]
            ),
            (
                "Office",
                [[
                    UTType.rtf.identifier: rich.rtf,
                    UTType.html.identifier: rich.html,
                    UTType.utf8PlainText.identifier: Data("Quarterly résumé".utf8),
                    "com.microsoft.ObjectLink": Data([0x4d, 0x53]),
                ]],
                [
                    UTType.rtf.identifier, UTType.html.identifier, UTType.utf8PlainText.identifier,
                    "public.utf16-external-plain-text", "com.microsoft.ObjectLink",
                ]
            ),
            (
                "Terminal",
                [[UTType.utf8PlainText.identifier: Data("printf 'ok'".utf8)]],
                [UTType.utf8PlainText.identifier]
            ),
        ]

        for fixture in fixtures {
            pasteboard.clearContents()
            _ = try Paster.place(fixture.payload, as: .original, to: pasteboard).get()
            XCTAssertEqual(placedTypes(), [fixture.original], fixture.name)

            let captured = Paster.snapshot(pasteboard).payload
            pasteboard.clearContents()
            _ = try Paster.place(captured, as: .plainText, to: pasteboard).get()
            let expected = fixture.name == "Terminal" ? "printf 'ok'" : "Quarterly résumé"
            XCTAssertEqual(pasteboard.string(forType: .string), expected, fixture.name)
            XCTAssertEqual(placedTypes(), [[UTType.utf8PlainText.identifier]], fixture.name)
        }
    }

    func testMultiItemOriginalRoundTripPreservesItemOrder() throws {
        let payload: ClipPayload = (0..<4).map { index in
            [UTType.fileURL.identifier: Data(URL(fileURLWithPath: "/tmp/ordered-\(index)").absoluteString.utf8)]
        }

        _ = try Paster.place(payload, as: .original, to: pasteboard).get()
        let captured = Paster.snapshot(pasteboard).payload

        XCTAssertEqual(ClipCapture.fileURLs(from: captured).map(\.lastPathComponent), [
            "ordered-0", "ordered-1", "ordered-2", "ordered-3",
        ])
        XCTAssertEqual(captured.count, 4)
    }

    func testMalformedOrOversizedRichRepresentationsFallBackToBoundedPlainText() throws {
        let payload: ClipPayload = [[
            UTType.rtf.identifier: Data(repeating: 0x7b, count: ClipPasteboardTypePolicy.maximumRichTextBytes + 1),
            UTType.html.identifier: Data("<script>while(true){}</script>".utf8),
            UTType.utf8PlainText.identifier: Data("safe fallback".utf8),
        ]]

        for mode in [PasteAsMode.richText, .rtf, .html] {
            pasteboard.clearContents()
            _ = try Paster.place(payload, as: mode, to: pasteboard).get()
            XCTAssertEqual(pasteboard.string(forType: .string), "safe fallback")
            XCTAssertLessThanOrEqual(
                pasteboard.pasteboardItems?.first?.types.count ?? .max,
                mode == .richText ? 4 : (mode == .rtf ? 3 : 2)
            )
        }

        let htmlOnly: ClipPayload = [[
            UTType.html.identifier: Data(
                repeating: 0x3c, count: ClipPasteboardTypePolicy.maximumRichTextBytes + 1
            )
        ]]
        XCTAssertNil(ClipCapture.plainText(from: htmlOnly))
    }

    func testPayloadDecoderRejectsNonBinaryAndOversizedPropertyListsBeforeParsing() {
        let xml = Data("<?xml version=\"1.0\"?><plist><array></array></plist>".utf8)
        XCTAssertNil(ClipPayloadCoder.decode(xml))
        XCTAssertNil(
            ClipPayloadCoder.decode(
                Data(repeating: 0, count: ClipPayloadCoder.maximumEncodedBytes + 1)
            )
        )
    }

    func testOneProviderIsProducedForEveryDraggedFileAndDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-interop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("a.txt")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let fileB = root.appendingPathComponent("b.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileA.path, contents: Data("a".utf8)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: fileB.path, contents: Data([1, 2, 3])))
        let urls = [fileA, folder, fileB]

        let providers = ClipDragItem.fileProviders(for: urls, ownDragID: UUID())

        XCTAssertEqual(providers.count, urls.count)
        XCTAssertTrue(providers.allSatisfy {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && $0.registeredTypeIdentifiers.contains(ClipDragItem.privateTypeIdentifier)
        })

        let primary = ClipDragItem.primaryProvider(bundling: providers)
        // The SwiftUI compatibility provider carries its sibling set into the AppKit
        // bridge; the bridge must create one dragging item rather than one aggregate.
        XCTAssertEqual(
            ClipDragItem.draggingItems(representedBy: primary, at: .zero).count,
            urls.count,
            "the AppKit bridge must receive one dragging item per Finder object"
        )
        ClipDragItem.releaseBundle(representedBy: primary)
        XCTAssertEqual(ClipDragItem.providers(representedBy: primary).count, 1)
    }

    func testDropIntakePreservesEveryFileDirectoryAndImageInProviderOrder() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/first.txt"),
            URL(fileURLWithPath: "/tmp/a-directory", isDirectory: true),
            URL(fileURLWithPath: "/tmp/third.png"),
        ]
        let fileProviders = urls.map { url -> NSItemProvider in
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
            ) { completion in
                completion(Data(url.absoluteString.utf8), nil)
                return nil
            }
            return provider
        }
        let filesRead = expectation(description: "all files")
        ClipDropIntake.read(fileProviders) { payload, kind in
            XCTAssertEqual(kind, .files)
            XCTAssertEqual(ClipCapture.fileURLs(from: payload ?? []).map(\.lastPathComponent), [
                "first.txt", "a-directory", "third.png",
            ])
            filesRead.fulfill()
        }

        let imageBytes = try (1...3).map { try encodedImage(type: UTType.png.identifier, width: $0) }
        let imageProviders = imageBytes.map { bytes -> NSItemProvider in
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier, visibility: .all
            ) { completion in
                completion(bytes, nil)
                return nil
            }
            return provider
        }
        let imagesRead = expectation(description: "all images")
        ClipDropIntake.read(imageProviders) { payload, kind in
            XCTAssertEqual(kind, .image)
            XCTAssertEqual(payload?.map { $0[UTType.png.identifier] }, imageBytes.map(Optional.some))
            imagesRead.fulfill()
        }

        wait(for: [filesRead, imagesRead], timeout: 2)
    }

    func testDropIntakeDoesNotSilentlyAcceptAPartialMultiFileDrop() {
        let valid = NSItemProvider()
        valid.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
        ) { completion in
            completion(Data(URL(fileURLWithPath: "/tmp/valid").absoluteString.utf8), nil)
            return nil
        }
        let broken = NSItemProvider()
        broken.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
        ) { completion in
            completion(nil, NSError(domain: "test", code: 1))
            return nil
        }

        let completed = expectation(description: "all or nothing")
        ClipDropIntake.read([valid, broken]) { payload, kind in
            XCTAssertNil(payload)
            XCTAssertNil(kind)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testDropIntakeDeadlineCompletesExactlyOnceAndCancelsAStuckProvider() {
        let stuck = ProviderProbe(type: UTType.png.identifier, data: Data([1]), delay: nil)
        let completed = expectation(description: "deadline")
        let noSecondCompletion = expectation(description: "exactly once")
        noSecondCompletion.isInverted = true
        var count = 0

        ClipDropIntake.read(
            [stuck.provider],
            limits: .init(
                maximumProviderCount: 4, maximumItemBytes: 32,
                maximumTotalBytes: 32, maximumFileURLBytes: 32, timeout: 0.03
            )
        ) { payload, kind in
            count += 1
            if count == 1 {
                XCTAssertNil(payload)
                XCTAssertNil(kind)
                completed.fulfill()
            } else {
                noSecondCompletion.fulfill()
            }
        }

        wait(for: [completed, noSecondCompletion], timeout: 0.15)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(stuck.progress.isCancelled)
    }

    func testDropIntakeIgnoresALateProviderCallbackAfterDeadline() {
        let late = ProviderProbe(type: UTType.png.identifier, data: Data([7]), delay: 0.08)
        let completed = expectation(description: "deadline")
        var count = 0
        ClipDropIntake.read(
            [late.provider],
            limits: .init(
                maximumProviderCount: 4, maximumItemBytes: 32,
                maximumTotalBytes: 32, maximumFileURLBytes: 32, timeout: 0.02
            )
        ) { payload, kind in
            count += 1
            XCTAssertNil(payload)
            XCTAssertNil(kind)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 0.2)

        let lateCallbackWindow = expectation(description: "late callback arrived")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
            lateCallbackWindow.fulfill()
        }
        wait(for: [lateCallbackWindow], timeout: 0.2)
        XCTAssertEqual(count, 1)
    }

    func testDropIntakeRejectsProviderCountPerItemAndAggregateByteOverruns() throws {
        let probes = (0..<3).map {
            ProviderProbe(type: UTType.png.identifier, data: Data([$0]), delay: 0)
        }
        let providerCount = expectation(description: "provider count")
        ClipDropIntake.read(
            probes.map(\.provider),
            limits: .init(
                maximumProviderCount: 2, maximumItemBytes: 32,
                maximumTotalBytes: 64, maximumFileURLBytes: 32, timeout: 1
            )
        ) { payload, kind in
            XCTAssertNil(payload)
            XCTAssertNil(kind)
            providerCount.fulfill()
        }

        let oversized = ProviderProbe(
            type: UTType.png.identifier, data: Data(repeating: 1, count: 33), delay: 0
        )
        let itemBytes = expectation(description: "item bytes")
        ClipDropIntake.read(
            [oversized.provider],
            limits: .init(
                maximumProviderCount: 2, maximumItemBytes: 32,
                maximumTotalBytes: 64, maximumFileURLBytes: 32, timeout: 1
            )
        ) { payload, kind in
            XCTAssertNil(payload)
            XCTAssertNil(kind)
            itemBytes.fulfill()
        }

        let aggregateImage = try encodedImage(type: UTType.png.identifier, width: 2, height: 2)
        let aggregate = (0..<2).map { _ in
            ProviderProbe(type: UTType.png.identifier, data: aggregateImage, delay: 0)
        }
        let totalBytes = expectation(description: "total bytes")
        ClipDropIntake.read(
            aggregate.map(\.provider),
            limits: .init(
                maximumProviderCount: 2, maximumItemBytes: aggregateImage.count,
                maximumTotalBytes: aggregateImage.count * 2 - 1,
                maximumFileURLBytes: 8, timeout: 1
            )
        ) { payload, kind in
            XCTAssertNil(payload)
            XCTAssertNil(kind)
            totalBytes.fulfill()
        }

        wait(for: [providerCount, itemBytes, totalBytes], timeout: 2)
        XCTAssertTrue(probes.allSatisfy { $0.loadCount == 0 })
    }

    func testDropIntakeRejectsMixedProviderKindsBeforeMaterializingAnySubset() {
        let file = ProviderProbe(
            type: UTType.fileURL.identifier,
            data: Data(URL(fileURLWithPath: "/tmp/a").absoluteString.utf8), delay: 0
        )
        let image = ProviderProbe(type: UTType.png.identifier, data: Data([1]), delay: 0)
        let text = ProviderProbe(
            type: UTType.utf8PlainText.identifier, data: Data("hello".utf8), delay: 0
        )
        let completed = expectation(description: "mixed rejected")

        ClipDropIntake.read([file.provider, image.provider, text.provider]) { payload, kind in
            XCTAssertNil(payload)
            XCTAssertNil(kind)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual([file.loadCount, image.loadCount, text.loadCount], [0, 0, 0])
    }

    func testDropIntakeRejectsNonFileNulAndOversizedFileURLs() {
        let cases: [Data] = [
            Data("https://example.com/not-a-file".utf8),
            Data("file:///tmp/evil\0suffix".utf8),
            Data(("file:///tmp/" + String(repeating: "a", count: 80)).utf8),
        ]
        let completions = cases.indices.map { expectation(description: "invalid url \($0)") }
        for (index, data) in cases.enumerated() {
            let probe = ProviderProbe(type: UTType.fileURL.identifier, data: data, delay: 0)
            ClipDropIntake.read(
                [probe.provider],
                limits: .init(
                    maximumProviderCount: 2, maximumItemBytes: 128,
                    maximumTotalBytes: 128, maximumFileURLBytes: 64, timeout: 1
                )
            ) { payload, kind in
                XCTAssertNil(payload)
                XCTAssertNil(kind)
                completions[index].fulfill()
            }
        }
        wait(for: completions, timeout: 2)
    }

    func testRealPasteboardEntryKeepsUnknownSiblingProviderForAtomicPreflight() {
        let knownType = UTType.utf8PlainText.identifier
        let unknownType = "com.example.unregistered-drag-object"
        let (known, knownProbe) = lazyPasteboardItem(type: knownType, data: Data("safe".utf8))
        let (unknown, unknownProbe) = lazyPasteboardItem(type: unknownType, data: Data([1]))
        let dragPasteboard = NSPasteboard.withUniqueName()
        dragPasteboard.clearContents()
        XCTAssertTrue(dragPasteboard.writeObjects([known, unknown]))

        let nativeKnown = ProviderProbe(type: knownType, data: Data("safe".utf8), delay: 0)
        XCTAssertFalse(
            ClipDropIntake.preflightCompleteSession(
                pasteboard: dragPasteboard, nativeProviders: [nativeKnown.provider]
            ),
            "a filtered native-provider list must not hide an unknown sibling item"
        )
        XCTAssertTrue(knownProbe.requestedTypes.isEmpty)
        XCTAssertTrue(unknownProbe.requestedTypes.isEmpty)
        XCTAssertEqual(nativeKnown.loadCount, 0)
    }

    func testCompleteSessionPreflightDoesNotRetainPasteboardItemForAsyncRead() {
        let type = UTType.utf8PlainText.identifier
        let (item, pasteboardProbe) = lazyPasteboardItem(type: type, data: Data("proxy".utf8))
        let dragPasteboard = NSPasteboard.withUniqueName()
        dragPasteboard.clearContents()
        XCTAssertTrue(dragPasteboard.writeObjects([item]))

        let native = ProviderProbe(type: type, data: Data("native".utf8), delay: 0)
        XCTAssertTrue(
            ClipDropIntake.preflightCompleteSession(
                pasteboard: dragPasteboard, nativeProviders: [native.provider]
            )
        )
        dragPasteboard.clearContents()

        let completed = expectation(description: "native provider survives drag pasteboard cleanup")
        ClipDropIntake.read([native.provider]) { payload, kind in
            XCTAssertEqual(kind, .text)
            XCTAssertEqual(payload?.first?[UTType.utf8PlainText.identifier], Data("native".utf8))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertTrue(pasteboardProbe.requestedTypes.isEmpty)
        XCTAssertEqual(native.loadCount, 1)
    }

    func testJPEGHEICAndGIFFullCapturePreviewThumbnailAndOriginalDragLifecycle() throws {
        for type in [UTType.jpeg.identifier, UTType.heic.identifier, UTType.gif.identifier] {
            let original = try encodedImage(type: type)
            let item = NSPasteboardItem()
            item.setData(original, forType: NSPasteboard.PasteboardType(type))
            guard case .captured(let payload, let kind, _) = ClipCapture.read(
                items: [item], options: .init()
            ) else {
                XCTFail("\(type) was not captured")
                continue
            }
            XCTAssertEqual(kind, .image)
            XCTAssertEqual(payload.first?[type], original, "original bytes must survive capture")
            XCTAssertNotNil(payload.first?[UTType.png.identifier], "Store needs a normalized PNG")
            let preview = try XCTUnwrap(ClipCapture.image(from: payload))
            XCTAssertEqual(Int(preview.size.width), 16)
            XCTAssertEqual(Int(preview.size.height), 12)

            let analysis = ClipCapture.PayloadAnalysis(
                digest: ClipPayloadCoder.digest(payload),
                byteSize: ClipPayloadCoder.byteSize(payload), plainText: nil
            )
            let preparation = ClipStore.prepareCapturedPayload(
                payload, kind: .image, analysis: analysis
            )
            XCTAssertEqual(preparation.image?.pixelWidth, 16)
            XCTAssertEqual(preparation.image?.pixelHeight, 12)
            XCTAssertNotNil(preparation.image?.thumbnailData)

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("hyper-image-lifecycle-\(UUID().uuidString)", isDirectory: true)
            let store = ClipStore(root: root)
            let loaded = expectation(description: "store \(type)")
            store.whenLoaded { loaded.fulfill() }
            wait(for: [loaded], timeout: 5)
            let record = store.insert(ClipStore.Insertion(
                payload: payload, kind: .image, oversized: false,
                byteSize: ClipPayloadCoder.byteSize(payload), sourceBundleID: nil,
                sourceName: "Tests", prepared: preparation
            ))
            store.waitForPendingWrites()
            let provider = try XCTUnwrap(ClipDragItem.providers(for: record, store: store).first)
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains(type))
            let dragged = expectation(description: "drag original \(type)")
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                XCTAssertNil(error)
                XCTAssertEqual(data, original)
                dragged.fulfill()
            }
            wait(for: [dragged], timeout: 2)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testMultiFileDragHitTestingConvertsSuperviewPointWithANonzeroFrameOrigin() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let view = MultiFileDragNSView(frame: NSRect(x: 140, y: 75, width: 80, height: 30))
        root.addSubview(view)
        view.hitTestEventType = { .leftMouseDown }

        XCTAssertTrue(view.hitTest(NSPoint(x: 144, y: 79)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 224, y: 79)))
    }

    private final class PasteboardProbe: NSObject, NSPasteboardItemDataProvider {
        let type: String
        let data: Data
        private(set) var requestedTypes: [String] = []

        init(type: String, data: Data) {
            self.type = type
            self.data = data
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            requestedTypes.append(type.rawValue)
            if type.rawValue == self.type { item.setData(data, forType: type) }
        }
    }

    private func lazyPasteboardItem(
        type: String, data: Data
    ) -> (NSPasteboardItem, PasteboardProbe) {
        let item = NSPasteboardItem()
        let probe = PasteboardProbe(type: type, data: data)
        item.setDataProvider(probe, forTypes: [NSPasteboard.PasteboardType(type)])
        return (item, probe)
    }
}
