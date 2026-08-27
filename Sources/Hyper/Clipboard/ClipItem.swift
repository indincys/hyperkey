import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a clipboard entry is, for filtering and for picking how to draw it.
enum ClipKind: String, Codable, CaseIterable {
    case text
    case richText
    case url
    case image
    case files
    case color

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .url: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .color: return "paintpalette"
        }
    }

    var label: String {
        switch self {
        case .text: return "文本"
        case .richText: return "富文本"
        case .url: return "链接"
        case .image: return "图片"
        case .files: return "文件"
        case .color: return "颜色"
        }
    }
}

/// What a piece of text *is*, past the pasteboard types that decided its `ClipKind`.
///
/// A second, softer classification: `ClipKind` comes from the types the source
/// application wrote and is always right, while this is read off the characters
/// themselves and is only ever a guess. So it is optional everywhere, it never changes
/// how an entry is stored or pasted, and it is deliberately shy — a wrong badge on a row
/// is worse than no badge, because the row is then describing something else.
enum ClipContentTag: String, Codable, CaseIterable {
    case email
    case phone
    case path
    case json
    case code

    var label: String {
        switch self {
        case .email: return "邮箱"
        case .phone: return "电话"
        case .path: return "路径"
        case .json: return "JSON"
        case .code: return "代码"
        }
    }

    var symbolName: String {
        switch self {
        case .email: return "envelope"
        case .phone: return "phone"
        case .path: return "folder"
        case .json: return "curlybraces"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Whether the content is the kind of thing whose alignment carries meaning, and so
    /// should be drawn in a monospaced face wherever it is shown.
    var prefersMonospace: Bool {
        switch self {
        case .json, .code, .path: return true
        case .email, .phone: return false
        }
    }
}

/// The raw pasteboard contents: one dictionary per pasteboard *item* (copying three
/// files produces three items), each mapping a type identifier to its data.
///
/// Keeping every type rather than just the plain string is what lets a paste land in
/// the target application's preferred format — styled text stays styled in Pages, and
/// the same entry still pastes as plain text into a terminal.
typealias ClipPayload = [[String: Data]]

/// One bounded ImageIO path for every image representation Hyper accepts.
///
/// JPEG/HEIC/GIF bytes stay in the payload unchanged for lossless round trips. A PNG
/// first-frame representation is added for the existing thumbnail and dimension path,
/// which means every accepted format has the same row/preview lifecycle without asking
/// AppKit to decode untrusted image bytes on the main thread.
enum ClipImageCodec {
    static let maximumEncodedBytes = 20 * 1024 * 1024
    static let maximumPixelCount = 25_000_000
    static let maximumDimension = 16_384

    static let typeIdentifiers = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier,
        UTType.gif.identifier, UTType.tiff.identifier,
    ]

    struct DecodedImage {
        let image: CGImage
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func decode(_ data: Data) -> DecodedImage? {
        guard let dimensions = dimensions(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        return DecodedImage(
            image: image, pixelWidth: dimensions.width, pixelHeight: dimensions.height
        )
    }

    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard !data.isEmpty, data.count <= maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixelCount / height
        else { return nil }
        return (width, height)
    }

    static func encode(
        _ image: CGImage, as type: String, maximumBytes: Int = maximumEncodedBytes
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type as CFString, 1, nil
        ) else { return nil }
        let properties: CFDictionary? = type == UTType.jpeg.identifier
            ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = output as Data
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        return data
    }

    /// Validates all image representations, drops malformed siblings, retains every
    /// valid original, and supplies PNG where the Store's thumbnail pipeline needs it.
    static func augmentedPayload(
        _ payload: ClipPayload, maximumTotalBytes: Int
    ) -> ClipPayload? {
        guard maximumTotalBytes > 0 else { return nil }
        var output: ClipPayload = []
        output.reserveCapacity(payload.count)
        var total = 0

        for bucket in payload {
            var safe = bucket.filter { !typeIdentifiers.contains($0.key) }
            let validImages = typeIdentifiers.compactMap { type -> (String, Data)? in
                guard let data = bucket[type], decode(data) != nil else { return nil }
                return (type, data)
            }
            guard !validImages.isEmpty else { return nil }
            for (type, data) in validImages { safe[type] = data }

            if safe[UTType.png.identifier] == nil,
               safe[UTType.tiff.identifier] == nil,
               let source = validImages.first,
               let decoded = decode(source.1),
               let png = encode(decoded.image, as: UTType.png.identifier) {
                safe[UTType.png.identifier] = png
            }
            guard safe[UTType.png.identifier] != nil || safe[UTType.tiff.identifier] != nil else {
                return nil
            }

            for data in safe.values {
                guard total <= maximumTotalBytes - data.count else { return nil }
                total += data.count
            }
            output.append(safe)
        }
        return output
    }

    static func image(from payload: ClipPayload) -> NSImage? {
        for item in payload {
            for type in typeIdentifiers {
                guard let data = item[type], let decoded = decode(data) else { continue }
                // `NSImage(cgImage:size:)` treats the supplied point size as Retina and
                // reports a representation twice the source dimensions. Attach the
                // bitmap representation explicitly so dimension metadata stays exact.
                let representation = NSBitmapImageRep(cgImage: decoded.image)
                representation.size = NSSize(
                    width: decoded.pixelWidth, height: decoded.pixelHeight
                )
                let image = NSImage(size: representation.size)
                image.addRepresentation(representation)
                return image
            }
        }
        return nil
    }

    static func representation(
        from payload: ClipPayload, requestedType: String
    ) -> Data? {
        guard typeIdentifiers.contains(requestedType) else { return nil }
        for item in payload {
            if let exact = item[requestedType], decode(exact) != nil { return exact }
        }
        guard let decoded = decodedSource(from: payload) else { return nil }
        return encode(decoded.image, as: requestedType)
    }

    private static func decodedSource(from payload: ClipPayload) -> DecodedImage? {
        for item in payload {
            for type in typeIdentifiers {
                if let data = item[type], let decoded = decode(data) { return decoded }
            }
        }
        return nil
    }
}

/// One policy for every boundary where pasteboard representations enter or leave Hyper.
///
/// A clipboard item is not a bag of harmless labels: a receiving application selects a
/// decoder from the advertised identifier. Re-publishing arbitrary private identifiers
/// therefore turns old history into an input to decoders Hyper knows nothing about. The
/// policy keeps the public formats that make clipboard interoperability useful, plus a
/// deliberately small set of browser/iWork/Office formats observed in real copy flows.
/// Bookkeeping, promises, executable/archive containers, and unknown private formats are
/// retained neither in new captures nor in an `original` paste.
enum ClipPasteboardTypePolicy {
    static let maximumRichTextBytes = 2 * 1024 * 1024
    static let maximumPrivateRepresentationBytes = 8 * 1024 * 1024

    /// High-value public types in the order providers should be asked for and targets
    /// should see them registered. Exact identifiers keep `public.executable`, arbitrary
    /// archives and other overly broad `public.*` types out of the trust boundary.
    static let preferredPublicTypeIdentifiers: [String] = [
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.utf8PlainText.identifier,
        "public.utf16-external-plain-text",
        "public.utf16-plain-text",
        UTType.plainText.identifier,
        UTType.rtf.identifier,
        UTType.html.identifier,
        "com.apple.flat-rtfd",
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.heic.identifier,
        UTType.tiff.identifier,
        UTType.gif.identifier,
        UTType.pdf.identifier,
        UTType.vCard.identifier,
        UTType.json.identifier,
        "public.comma-separated-values-text",
        "public.utf8-tab-separated-values-text",
        NSPasteboard.PasteboardType.color.rawValue,
    ]

    /// Private representations whose producer and serialization contract are known.
    /// They preserve native Safari, Chromium, iWork and Microsoft Office round-trips;
    /// this is an exact list rather than namespace prefixes on purpose.
    static let interoperablePrivateTypeIdentifiers: Set<String> = [
        "com.apple.WebKit.custom-pasteboard-data",
        "com.apple.webarchive",
        "com.apple.webpasteboard",
        "com.apple.iWork.TSPNativeData",
        "org.chromium.web-custom-data",
        "com.microsoft.ObjectLink",
        "com.microsoft.Link Source",
        "com.microsoft.ole.data",
    ]

    private static let publicTypes = Set(preferredPublicTypeIdentifiers)
    private static let richTypes: Set<String> = [
        UTType.rtf.identifier, UTType.html.identifier, "com.apple.flat-rtfd",
    ]
    private static let binaryPlistPrivateTypes: Set<String> = [
        "com.apple.WebKit.custom-pasteboard-data", "com.apple.webarchive",
        "com.apple.webpasteboard",
    ]

    static func isAllowListedIdentifier(_ identifier: String) -> Bool {
        publicTypes.contains(identifier) || interoperablePrivateTypeIdentifiers.contains(identifier)
    }

    static func canMaterialize(_ identifier: String) -> Bool {
        // Asking a lazy pasteboard provider for an unknown private type can itself invoke
        // application code, allocate an unbounded object graph, or deserialize an archive.
        // Only identifiers whose byte representation contract we explicitly know cross
        // that boundary; common Office/iWork/browser private formats are allow-listed above.
        isAllowListedIdentifier(identifier)
    }

    static func shouldPreserve(_ identifier: String, data: Data) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 255, !data.isEmpty else { return false }
        if publicTypes.contains(identifier) {
            return !richTypes.contains(identifier) || data.count <= maximumRichTextBytes
        }
        guard interoperablePrivateTypeIdentifiers.contains(identifier),
              data.count <= maximumPrivateRepresentationBytes
        else { return false }
        if binaryPlistPrivateTypes.contains(identifier) {
            return data.count >= 8 && data.prefix(8).elementsEqual(Data("bplist00".utf8))
        }
        return true
    }

    static func sanitized(_ payload: ClipPayload) -> ClipPayload {
        payload.compactMap { bucket in
            let safe = bucket.filter { shouldPreserve($0.key, data: $0.value) }
            return safe.isEmpty ? nil : safe
        }
    }

    static func orderedRepresentations(in bucket: [String: Data]) -> [(String, Data)] {
        let order = Dictionary(
            uniqueKeysWithValues: preferredPublicTypeIdentifiers.enumerated().map { ($1, $0) }
        )
        return bucket.sorted {
            let left = order[$0.key] ?? (interoperablePrivateTypeIdentifiers.contains($0.key) ? 10_000 : 20_000)
            let right = order[$1.key] ?? (interoperablePrivateTypeIdentifiers.contains($1.key) ? 10_000 : 20_000)
            return left == right ? $0.key < $1.key : left < right
        }
    }

    static func priority(of identifier: String) -> Int {
        if let index = preferredPublicTypeIdentifiers.firstIndex(of: identifier) { return index }
        if interoperablePrivateTypeIdentifiers.contains(identifier) { return 10_000 }
        return 20_000
    }
}

/// The index entry. Deliberately small: everything here is held in memory for the
/// lifetime of the process, while the payload and the thumbnail live in their own
/// files and are read only when a row is actually shown or pasted.
struct ClipRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var createdAt: Date
    var kind: ClipKind
    /// Plain-text stand-in used for both the row label and search.
    var preview: String
    /// Digest of the payload, used to collapse a repeated copy into a bump.
    var digest: String
    var byteSize: Int
    var sourceBundleID: String?
    var sourceName: String?
    var pinned: Bool = false
    /// Where a pinned entry sits inside the 收藏 band, lowest first.
    ///
    /// The band is the one part of the history whose order is the user's rather than the
    /// clock's, so it needs a number of its own — sorting the pins by when they were
    /// copied would undo a rearrangement the moment anything was re-copied.
    ///
    /// Optional so an `index.json` written before this existed still decodes: those pins
    /// are handed ranks once, in the order they were already being shown in — see
    /// `ClipStore.backfillPinnedRanks`. Cleared when the pin comes off, so the field only
    /// ever means something on a row that is actually in the band.
    var pinnedRank: Int?
    /// Payload exceeded the per-entry cap and was dropped; the row is a record of
    /// *having copied* something, not something that can be pasted back.
    var oversized: Bool = false
    var hasThumbnail: Bool = false
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileCount: Int?
    /// `#RRGGBB` for a colour entry whose value could be read off the pasteboard.
    ///
    /// Optional so an `index.json` written before this existed still decodes: older
    /// colour rows simply keep showing their pasteboard text and no swatch.
    var colorHex: String?

    /// What the text looks like — an address, a path, a lump of JSON. Resolved once at
    /// capture, because the row and the preview both want it and neither should be
    /// running regexes while the pointer sweeps down the list.
    ///
    /// Optional for the same reason `colorHex` is: an index written before this existed
    /// decodes unchanged, and those rows simply wear no tag until they are edited.
    var contentTag: ClipContentTag?

    /// Identity plus everything a row is drawn from, because SwiftUI decides whether to
    /// redraw a row by comparing the two records. `digest` stands in for the body: an
    /// edit keeps the id, the date and the star but rewrites `preview`, `kind` and the
    /// digest together, and without it here the row would keep showing the old text.
    static func == (lhs: ClipRecord, rhs: ClipRecord) -> Bool {
        lhs.id == rhs.id && lhs.createdAt == rhs.createdAt && lhs.pinned == rhs.pinned
            && lhs.digest == rhs.digest
    }

    /// One short line under the title: where it came from and how long ago.
    func subtitle(now: Date = Date()) -> String {
        var parts: [String] = []
        if let sourceName, !sourceName.isEmpty { parts.append(sourceName) }
        parts.append(ClipRecord.relativeTime(from: createdAt, to: now))
        switch kind {
        case .image:
            if let w = pixelWidth, let h = pixelHeight { parts.append("\(w)×\(h)") }
        case .files:
            if let n = fileCount, n > 1 { parts.append("\(n) 个文件") }
        default:
            break
        }
        // Last, because it is the softest thing on the line: where the entry came from
        // and when are facts, and what it looks like is a reading of it.
        if let contentTag { parts.append(contentTag.label) }
        return parts.joined(separator: " · ")
    }

    static func relativeTime(from date: Date, to now: Date) -> String {
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
}

// MARK: - Colour

/// A colour, stored as sRGB components, with the three notations people actually paste.
///
/// Held as components rather than as an `NSColor` because that is what the record keeps
/// on disk: a hex string is stable across colour-space changes and readable in
/// `index.json`, and every conversion below is cheap enough to redo on demand.
struct ClipColorValue: Equatable {
    /// 0…1, sRGB.
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Accepts `#RGB` and `#RRGGBB`, with or without the hash.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 {
            // #ABC is #AABBCC — expand rather than reject, since that is what CSS means.
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    init(nsColor: NSColor) {
        // Pattern and catalogue colours have no components at all until they are
        // converted, and `usingColorSpace` is the only conversion that cannot trap.
        let srgb = nsColor.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }

    private var bytes: (Int, Int, Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var hexString: String {
        let (r, g, b) = bytes
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var rgbString: String {
        let (r, g, b) = bytes
        return "rgb(\(r), \(g), \(b))"
    }

    var hslString: String {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2

        var hue = 0.0
        if delta > 0 {
            switch maximum {
            case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            case green: hue = (blue - red) / delta + 2
            default: hue = (red - green) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        return "hsl(\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}

// MARK: - Payload coding

enum ClipPayloadCoder {
    /// Above the normal 20 MiB capture ceiling to leave room for historical payloads,
    /// but finite before Foundation's property-list parser sees any attacker-controlled
    /// bytes. Encoded payloads are never compressed, so this is also a memory bound.
    static let maximumEncodedBytes = 64 * 1024 * 1024
    private static let maximumItems = 4_096
    private static let maximumRepresentations = 16_384
    private static let maximumDecodedBytes = 64 * 1024 * 1024

    /// A binary property list — `[[String: Data]]` is already a valid plist object, so
    /// this needs no schema of its own and stays readable with `plutil`.
    static func encode(_ payload: ClipPayload) -> Data? {
        guard payload.count <= maximumItems,
              payload.reduce(0, { $0 + $1.count }) <= maximumRepresentations,
              byteSize(payload) <= maximumDecodedBytes
        else { return nil }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        ), data.count <= maximumEncodedBytes else { return nil }
        return data
    }

    static func decode(_ data: Data) -> ClipPayload? {
        guard data.count >= 8, data.count <= maximumEncodedBytes,
              data.prefix(8).elementsEqual(Data("bplist00".utf8))
        else { return nil }
        guard let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ), let payload = object as? ClipPayload,
              payload.count <= maximumItems
        else { return nil }

        var representationCount = 0
        var decodedBytes = 0
        for bucket in payload {
            representationCount += bucket.count
            guard representationCount <= maximumRepresentations else { return nil }
            for (identifier, value) in bucket {
                guard !identifier.isEmpty, identifier.count <= 255 else { return nil }
                let (next, overflowed) = decodedBytes.addingReportingOverflow(value.count)
                guard !overflowed, next <= maximumDecodedBytes else { return nil }
                decodedBytes = next
            }
        }
        return payload
    }

    static func byteSize(_ payload: ClipPayload) -> Int {
        var total = 0
        for data in payload.flatMap(\.values) {
            let (next, overflowed) = total.addingReportingOverflow(data.count)
            if overflowed { return .max }
            total = next
        }
        return total
    }

    static func digest(_ payload: ClipPayload) -> String {
        var hasher = SHA256()
        // Type order within an item is not stable across reads, so sort before hashing
        // or the same copy would produce a different digest on different runs.
        for item in payload {
            for key in item.keys.sorted() {
                hasher.update(data: Data(key.utf8))
                hasher.update(data: item[key] ?? Data())
            }
            hasher.update(data: Data([0x1e]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Capture

enum ClipCapture {
    /// Types whose presence means "do not record this".
    ///
    /// `ConcealedType` is the convention password managers (1Password, Keychain
    /// Access, Bitwarden …) use to mark a copied secret. Honouring it is the reason a
    /// clipboard history is safe to leave running.
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    static let transientTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "com.apple.finder.noindex",
    ]

    /// Markers and app-private bookkeeping that should never be written back out.
    private static let excludedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "org.nspasteboard.source",
    ]

    /// A small, content-free identity seed handed to the store for an oversized row.
    /// Without it every stripped payload would hash as the same empty value, causing
    /// unrelated oversized copies to collapse into one history entry.
    static let oversizedMetadataType = "dev.hyper.capture.oversized-metadata"

    struct Options {
        var recordImages = true
        var skipConcealed = true
        var skipTransient = true
        /// Aggregate bytes materialised for one clipboard change.
        var maxItemBytes = 20 * 1024 * 1024
        /// A single representation may be held to a tighter limit than the aggregate.
        /// `nil` means the aggregate limit. AppKit does not expose a byte-count probe,
        /// so this is checked immediately *after* the provider returns its `Data`.
        var maxTypeBytes: Int? = nil
        /// Bounds pathological items that advertise hundreds of lazy/private types.
        /// This counts calls to `data(forType:)`, including providers that return nil.
        var maxTypeReads = 512
    }

    enum Outcome {
        case captured(ClipPayload, ClipKind, Reduction)
        case ignored(String)
    }

    struct Reduction {
        /// No pasteable representation fit; only stable metadata survives.
        var oversized = false
        /// Some representations were omitted, but the payload still contains at least
        /// one public/high-value representation and remains pasteable.
        var truncated = false
        /// Bytes actually observed before capture stopped. When
        /// `byteSizeIsLowerBound` is true, unread providers may contain more.
        var byteSize = 0
        /// Source bytes observed for budgeting. Differs from `byteSize` only for a
        /// truncated-but-pasteable payload, where `byteSize` is the retained payload's
        /// real size so storage/UI accounting remains truthful.
        var observedByteSize = 0
        var byteSizeIsLowerBound = false
        var requestedTypeCount = 0
    }

    /// Pure post-capture work that is safe to run away from AppKit and the main thread.
    /// It intentionally does not parse RTF/HTML or decode images.
    struct PayloadAnalysis {
        let digest: String
        let byteSize: Int
        let plainText: String?
    }

    private static let payloadAnalysisQueue = DispatchQueue(
        label: "dev.hyper.clipboard.capture-analysis", qos: .utility,
        attributes: .concurrent
    )

    static func analyzePayloadOffMain(
        _ payload: ClipPayload, completion: @escaping (PayloadAnalysis) -> Void
    ) {
        payloadAnalysisQueue.async {
            completion(PayloadAnalysis(
                digest: ClipPayloadCoder.digest(payload),
                byteSize: ClipPayloadCoder.byteSize(payload),
                plainText: plainTextOnly(from: payload)
            ))
        }
    }

    /// Reads the pasteboard into a payload. Must run on the main thread, where the
    /// pasteboard is read everywhere else in the app.
    static func read(_ pasteboard: NSPasteboard, options: Options) -> Outcome {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return .ignored("empty")
        }

        return read(items: items, options: options)
    }

    /// The item overload is also the seam used by lazy-provider tests. It deliberately
    /// accepts actual `NSPasteboardItem`s: request ordering and early stopping need to
    /// be proven against AppKit's provider mechanism, not only against a fake reader.
    static func read(items: [NSPasteboardItem], options: Options) -> Outcome {
        guard !items.isEmpty else { return .ignored("empty") }

        let offeredTypesByItem = items.map { $0.types.map(\.rawValue) }
        let allTypes = Set(items.flatMap { $0.types.map(\.rawValue) })

        if options.skipConcealed, !allTypes.isDisjoint(with: concealedTypes) {
            return .ignored("concealed")
        }
        if options.skipTransient, !allTypes.isDisjoint(with: transientTypes) {
            return .ignored("transient")
        }

        let offeredKind = classify(allTypes, payload: [])
        if offeredKind == .image, !options.recordImages {
            return .ignored("images disabled")
        }

        struct Candidate {
            let itemIndex: Int
            let item: NSPasteboardItem
            let type: String
            let priority: Int
        }

        var candidates: [Candidate] = []
        for (itemIndex, item) in items.enumerated() {
            let offeredTypes = item.types.map(\.rawValue)
            // A screenshot arrives as both TIFF and PNG of the same picture, and the
            // TIFF is routinely ten times larger. Dropping it costs nothing — every
            // application that accepts an image accepts PNG — and it is the difference
            // between a screenshot fitting under the size cap and being thrown away.
            let dropTIFF = offeredTypes.contains(NSPasteboard.PasteboardType.png.rawValue)
            for type in offeredTypes {
                if excludedTypes.contains(type) { continue }
                if dropTIFF, type == NSPasteboard.PasteboardType.tiff.rawValue { continue }
                if !ClipPasteboardTypePolicy.canMaterialize(type) { continue }
                candidates.append(Candidate(
                    itemIndex: itemIndex,
                    item: item,
                    type: type,
                    priority: capturePriority(for: type, offeredKind: offeredKind)
                ))
            }
        }

        // Priority is global, not merely within each item. A private representation on
        // item zero must not run before the public file URL on item one. Stable tie
        // breakers keep provider request order deterministic across applications.
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.itemIndex != $1.itemIndex { return $0.itemIndex < $1.itemIndex }
            return $0.type < $1.type
        }

        var reduction = Reduction()
        var buckets = Array(repeating: [String: Data](), count: items.count)
        let totalLimit = max(0, options.maxItemBytes)
        let typeLimit = max(0, options.maxTypeBytes ?? totalLimit)
        let requestLimit = max(0, options.maxTypeReads)

        for (candidateIndex, candidate) in candidates.enumerated() {
            // No bytes remain, so asking another lazy provider cannot produce a
            // positive-sized representation that fits. Stop before triggering it.
            if reduction.observedByteSize >= totalLimit {
                reduction.byteSizeIsLowerBound = true
                return budgetExceededOutcome(
                    types: allTypes, offeredTypesByItem: offeredTypesByItem,
                    buckets: buckets, rejected: nil, reduction: reduction
                )
            }
            guard reduction.requestedTypeCount < requestLimit else {
                reduction.byteSizeIsLowerBound = true
                return budgetExceededOutcome(
                    types: allTypes, offeredTypesByItem: offeredTypesByItem,
                    buckets: buckets, rejected: nil, reduction: reduction
                )
            }

            reduction.requestedTypeCount += 1

            // This call can synchronously ask the source application to materialise a
            // lazy representation. NSPasteboardItem provides neither its byte count in
            // advance nor cancellation. Therefore one provider allocation cannot be
            // prevented here; what this layer guarantees is that the bytes are counted
            // and released immediately, and that no later provider is invoked.
            guard let data = candidate.item.data(
                forType: NSPasteboard.PasteboardType(candidate.type)
            ) else { continue }

            let (observedTotal, overflowed) = reduction.observedByteSize.addingReportingOverflow(data.count)
            reduction.observedByteSize = overflowed ? Int.max : observedTotal
            reduction.byteSize = reduction.observedByteSize
            let overTypeBudget = data.count > typeLimit
            let overTotalBudget = overflowed || reduction.observedByteSize > totalLimit
            if overTypeBudget || overTotalBudget {
                reduction.byteSizeIsLowerBound = candidateIndex + 1 < candidates.count
                return budgetExceededOutcome(
                    types: allTypes, offeredTypesByItem: offeredTypesByItem, buckets: buckets,
                    rejected: (candidate.itemIndex, candidate.type, data), reduction: reduction
                )
            }

            guard ClipPasteboardTypePolicy.shouldPreserve(candidate.type, data: data) else {
                reduction.truncated = true
                continue
            }
            buckets[candidate.itemIndex][candidate.type] = data
        }

        var payload = compact(buckets)
        guard !payload.isEmpty else { return .ignored("no readable types") }
        let kind = classify(allTypes, payload: payload)
        if kind == .image {
            guard let augmented = ClipImageCodec.augmentedPayload(
                payload, maximumTotalBytes: totalLimit
            ) else { return .ignored("invalid or over-budget image") }
            payload = augmented
            reduction.byteSize = ClipPayloadCoder.byteSize(payload)
        }
        return .captured(payload, kind, reduction)
    }

    private static func compact(_ buckets: ClipPayload) -> ClipPayload {
        buckets.filter { !$0.isEmpty }
    }

    private static func budgetExceededOutcome(
        types: Set<String>, offeredTypesByItem: [[String]], buckets: ClipPayload,
        rejected: (itemIndex: Int, type: String, data: Data)?, reduction original: Reduction
    ) -> Outcome {
        let retained = compact(buckets.map { bucket in
            bucket.filter { isRetainableAfterTruncation($0.key) }
        })
        var reduction = original
        if !retained.isEmpty {
            reduction.truncated = true
            reduction.oversized = false
            reduction.byteSize = ClipPayloadCoder.byteSize(retained)
            return .captured(retained, classify(types, payload: retained), reduction)
        }

        reduction.oversized = true
        reduction.truncated = false
        let kind = classify(types, payload: [])
        let marker = stableOversizedIdentity(
            kind: kind, offeredTypesByItem: offeredTypesByItem, buckets: buckets,
            rejected: rejected, reduction: reduction
        )
        return .captured([[oversizedMetadataType: marker]], kind, reduction)
    }

    private static func isRetainableAfterTruncation(_ type: String) -> Bool {
        // The value-dependent size/serialization check happens before a representation
        // enters `buckets`; reaching this point means its identifier is allow-listed.
        ClipPasteboardTypePolicy.preferredPublicTypeIdentifiers.contains(type)
            || ClipPasteboardTypePolicy.interoperablePrivateTypeIdentifiers.contains(type)
    }

    /// A stable, non-reversible identity. Metadata is always included; at most 16 KiB
    /// of the already-materialised content is sampled into SHA-256 and never retained.
    private static func stableOversizedIdentity(
        kind: ClipKind, offeredTypesByItem: [[String]], buckets: ClipPayload,
        rejected: (itemIndex: Int, type: String, data: Data)?, reduction: Reduction
    ) -> Data {
        var hasher = SHA256()
        func add(_ value: String) { hasher.update(data: Data(value.utf8)); hasher.update(data: Data([0])) }
        add(kind.rawValue)
        add(String(reduction.observedByteSize))
        add(reduction.byteSizeIsLowerBound ? "lower-bound" : "exact")
        for (index, types) in offeredTypesByItem.enumerated() {
            add("item:\(index)")
            for type in types.sorted() { add(type) }
        }

        var sampleBudget = 16 * 1024
        func addRepresentation(itemIndex: Int, type: String, data: Data) {
            add("observed:\(itemIndex):\(type):\(data.count)")
            guard sampleBudget > 0, !data.isEmpty else { return }
            let headCount = min(data.count, min(4 * 1024, sampleBudget))
            hasher.update(data: Data(data.prefix(headCount)))
            sampleBudget -= headCount
            let remaining = data.count - headCount
            guard remaining > 0, sampleBudget > 0 else { return }
            let tailCount = min(remaining, min(4 * 1024, sampleBudget))
            hasher.update(data: Data(data.suffix(tailCount)))
            sampleBudget -= tailCount
        }

        if let rejected {
            addRepresentation(itemIndex: rejected.itemIndex, type: rejected.type, data: rejected.data)
        }
        for (itemIndex, bucket) in buckets.enumerated() {
            for type in bucket.keys.sorted() {
                if let data = bucket[type] {
                    addRepresentation(itemIndex: itemIndex, type: type, data: data)
                }
            }
        }
        return Data(hasher.finalize())
    }

    /// Lower numbers are requested first. The primary lossless representation for the
    /// offered content leads, then public interoperable formats, then app bookkeeping.
    /// This keeps rich text, files and images compatible without letting a delayed
    /// private provider stand in front of the format users can actually paste elsewhere.
    private static func capturePriority(for type: String, offeredKind: ClipKind) -> Int {
        let fileURL = "public.file-url"
        let png = NSPasteboard.PasteboardType.png.rawValue
        let tiff = NSPasteboard.PasteboardType.tiff.rawValue
        let plainText = Set([
            NSPasteboard.PasteboardType.string.rawValue,
            "public.utf8-plain-text",
            "public.text",
        ])
        let rtf = NSPasteboard.PasteboardType.rtf.rawValue
        let html = NSPasteboard.PasteboardType.html.rawValue
        let color = NSPasteboard.PasteboardType.color.rawValue

        if (offeredKind == .text || offeredKind == .richText || offeredKind == .url),
           plainText.contains(type) {
            return 0
        }

        switch offeredKind {
        case .files where type == fileURL: return 0
        case .image where type == png: return 0
        case .image where ClipImageCodec.typeIdentifiers.contains(type): return 1
        case .color where type == color: return 0
        case .richText where type == rtf: return 1
        case .richText where type == html: return 2
        default: break
        }

        if type == fileURL { return 10 }
        if type == png { return 11 }
        if plainText.contains(type) { return 12 }
        if type == rtf { return 13 }
        if type == html { return 14 }
        if type == color { return 15 }
        if type == tiff { return 16 }
        return 100 + ClipPasteboardTypePolicy.priority(of: type)
    }

    private static func classify(_ types: Set<String>, payload: ClipPayload) -> ClipKind {
        if types.contains("public.file-url") { return .files }
        if !types.isDisjoint(with: Set(ClipImageCodec.typeIdentifiers)) {
            return .image
        }
        if types.contains(NSPasteboard.PasteboardType.color.rawValue) { return .color }

        let text = classificationText(from: payload) ?? ""
        if isURLLike(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return .url }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue) {
            return .richText
        }
        return .text
    }

    /// URL classification is a small main-thread capture decision, not full-text
    /// analysis. Refuse to decode an arbitrarily large string here; the complete UTF-8
    /// conversion belongs to `analyzePayloadOffMain`.
    private static func classificationText(from payload: ClipPayload) -> String? {
        let limit = 64 * 1024
        let candidates = [
            NSPasteboard.PasteboardType.string.rawValue,
            "public.utf8-plain-text",
            "public.text",
        ]
        for item in payload {
            for type in candidates {
                guard let data = item[type], data.count <= limit else { continue }
                if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    /// Whether a trimmed string reads as a link. One word, and a scheme people actually
    /// paste — `URL(string:)` alone accepts almost any fragment of text.
    private static func isURLLike(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https", "ftp", "mailto"].contains(scheme)
    }

    /// The kind a plain-text body classifies as, for an entry whose text was edited in
    /// place. Only ever `.url` or `.text`: the richer kinds are decided by pasteboard
    /// types, and an edit produces nothing but characters.
    static func textKind(for text: String) -> ClipKind {
        isURLLike(text.trimmingCharacters(in: .whitespacesAndNewlines)) ? .url : .text
    }

    // MARK: - Content tags

    /// How much text the character-level heuristics ever look at. They exist to put a
    /// four-character badge on a row; a copy must not get slower the longer it is.
    private static let tagScanLimit = 4 * 1024

    /// Past this, JSON is not even attempted. The parse is the one check here that has
    /// to read everything it is given, and it runs on the main thread inside `insert`.
    private static let tagJSONLimit = 64 * 1024

    /// What a piece of text looks like, or nothing when it looks like ordinary prose.
    ///
    /// Pure and order-dependent: the cheap, anchored, whole-string tests come first, so
    /// anything that *is* an address or a path is settled before the fuzzy code
    /// heuristic gets a chance to disagree with it. Everything here is written to say no
    /// — a row wearing the wrong tag misdescribes its own content, which is worse than
    /// the plain row it replaced.
    static func contentTag(for text: String) -> ClipContentTag? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bounded before anything walks it: the caller's text can be megabytes, and
        // none of these tests mean anything past the first few kilobytes anyway.
        let head = String(trimmed.prefix(tagScanLimit))
        let singleLine = head.count == trimmed.count && !head.contains(where: \.isNewline)

        if singleLine {
            if matches(head, #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#) {
                return .email
            }
            if isPhoneLike(head) { return .phone }
            if isPathLike(head) { return .path }
        }
        if isJSONLike(trimmed) { return .json }
        if isCodeLike(head) { return .code }
        return nil
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }

    /// Deliberately loose — country codes, spaces, dashes and brackets are all how
    /// people actually write a number down — but held to a plausible count of digits so
    /// that a year, a price or an order number does not become a phone call.
    private static func isPhoneLike(_ line: String) -> Bool {
        guard matches(line, #"^\+?[0-9(][0-9 ()\-]{5,22}$"#) else { return false }
        let digits = line.reduce(into: 0) { $0 += $1.isNumber ? 1 : 0 }
        return (7...20).contains(digits)
    }

    /// An absolute or home-relative path and nothing else. A path with a space in it is
    /// given up on rather than guessed at: the line would be indistinguishable from a
    /// sentence that happens to open with a slash.
    private static func isPathLike(_ line: String) -> Bool {
        guard line.hasPrefix("/") || line.hasPrefix("~/") else { return false }
        guard line.count > 1, !line.contains(where: \.isWhitespace) else { return false }
        return true
    }

    /// Parsed rather than pattern-matched: "starts with a brace" is true of far too much
    /// to badge anything on, and `JSONSerialization` is the only answer that is never
    /// wrong. Fragments are not accepted — a bare number is not what anyone means by it.
    private static func isJSONLike(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        let data = Data(trimmed.utf8)
        guard data.count <= tagJSONLimit else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Markers that are on their own enough to call something code. Each one is either
    /// punctuation no prose uses or a keyword followed by the syntax that keyword only
    /// ever has in a program.
    private static let strongCodeMarkers = [
        "#include", "#import ", "=>", "};", "func ", "def ", "function ", "fn ",
        "console.log", "printf(", "public static", "</", "/>", "::",
    ]

    /// Markers that are ordinary words elsewhere. Two of them together is the evidence;
    /// one on its own is a sentence about programming, not a program.
    private static let weakCodeMarkers = [
        "import ", "return ", "const ", "class ", "static ", "struct ", "if (", "for (",
        "while (", "() {", ");", "self.", "this.", "$(", "&&", "||", "!=", "==",
    ]

    /// Multi-line only, on purpose. A single line carrying one of these is far more
    /// often a sentence quoting an identifier than it is a program, and the tag has
    /// nothing to offer a one-liner anyway — the row already shows the whole of it.
    private static func isCodeLike(_ text: String) -> Bool {
        guard text.contains(where: \.isNewline) else { return false }
        if strongCodeMarkers.contains(where: text.contains) { return true }
        var hits = 0
        for marker in weakCodeMarkers where text.contains(marker) {
            hits += 1
            if hits >= 2 { return true }
        }
        return false
    }

    static func plainText(_ items: [NSPasteboardItem]) -> String? {
        for item in items {
            if let string = item.string(forType: .string), !string.isEmpty { return string }
        }
        return nil
    }

    /// The plain-text types and nothing else.
    ///
    /// Split out from `plainText(from:)` because the styled-text fallbacks below it go
    /// through `NSAttributedString`, which is main-thread-only. Anything reading a
    /// payload off the main thread has to stop here — the background search rebuild
    /// uses this one and accepts that an RTF-only entry from before the upgrade stays
    /// searchable by its preview alone.
    static func plainTextOnly(from payload: ClipPayload) -> String? {
        let candidates = [
            NSPasteboard.PasteboardType.string.rawValue,
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
            "public.utf16-plain-text",
            "public.text",
        ]
        for item in payload {
            for type in candidates {
                if let data = item[type], let string = decodeText(data, type: type),
                   !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    static func plainText(from payload: ClipPayload) -> String? {
        if let string = plainTextOnly(from: payload) { return string }
        // Fall back to unpacking styled text, so an RTF-only copy still has something
        // searchable rather than showing up as a blank row.
        for item in payload {
            if let data = item[NSPasteboard.PasteboardType.rtf.rawValue],
               data.count <= ClipPasteboardTypePolicy.maximumRichTextBytes,
               let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                return boundedStyledString(attributed.string)
            }
            if let data = item[NSPasteboard.PasteboardType.html.rawValue],
               data.count <= ClipPasteboardTypePolicy.maximumRichTextBytes,
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.html],
                   documentAttributes: nil
               ) {
                return boundedStyledString(attributed.string)
            }
        }
        return nil
    }

    private static let maximumPlainTextBytes = 8 * 1024 * 1024
    private static let maximumStyledTextCharacters = 4 * 1024 * 1024

    private static func decodeText(_ data: Data, type: String) -> String? {
        guard data.count <= maximumPlainTextBytes else { return nil }
        if type == "public.utf16-external-plain-text" || type == "public.utf16-plain-text"
            || data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .utf16)
    }

    private static func boundedStyledString(_ string: String) -> String? {
        guard string.count <= maximumStyledTextCharacters else { return nil }
        return string
    }

    static func fileURLs(from payload: ClipPayload) -> [URL] {
        payload.compactMap { item in
            guard let data = item["public.file-url"],
                  data.count <= 64 * 1024,
                  let string = String(data: data, encoding: .utf8),
                  !string.contains("\0"),
                  let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    /// The sRGB value of a colour entry, as `#RRGGBB`.
    ///
    /// The pasteboard carries a colour as an archived `NSColor`, so this is an unarchive
    /// rather than a parse. Anything that fails to come back as a colour returns nil and
    /// the entry stays an ordinary row — a swatch is worth having only when it is
    /// certainly the right colour.
    static func colorHex(from payload: ClipPayload) -> String? {
        for item in payload {
            guard let data = item[NSPasteboard.PasteboardType.color.rawValue],
                  let color = decodeColor(data)
            else { continue }
            return ClipColorValue(nsColor: color).hexString
        }
        // Some applications write only the notation as text beside the colour type.
        guard let text = plainTextOnly(from: payload),
              let value = ClipColorValue(hex: text)
        else { return nil }
        return value.hexString
    }

    private static func decodeColor(_ data: Data) -> NSColor? {
        guard data.count <= 256 * 1024 else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    static func image(from payload: ClipPayload) -> NSImage? {
        ClipImageCodec.image(from: payload)
    }

    /// The one-line label shown in the list. Collapses runs of whitespace so a copied
    /// code block does not turn into a row of blanks.
    static func makePreview(kind: ClipKind, payload: ClipPayload) -> String {
        switch kind {
        case .files:
            let urls = fileURLs(from: payload)
            let names = urls.map { $0.lastPathComponent }
            if names.isEmpty { return "文件" }
            return names.count == 1 ? names[0] : "\(names[0]) 等 \(names.count) 个文件"
        case .image:
            return "图片"
        case .color:
            // The parsed value first: a colour's own text is whatever the source
            // application happened to put alongside it, and often nothing useful.
            return colorHex(from: payload) ?? plainText(from: payload) ?? "颜色"
        case .text, .richText, .url:
            let raw = plainText(from: payload) ?? ""
            let collapsed = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? "（空白内容）" : String(collapsed.prefix(400))
        }
    }
}
