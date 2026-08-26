import AppKit
import CryptoKit
import Foundation

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

/// The raw pasteboard contents: one dictionary per pasteboard *item* (copying three
/// files produces three items), each mapping a type identifier to its data.
///
/// Keeping every type rather than just the plain string is what lets a paste land in
/// the target application's preferred format — styled text stays styled in Pages, and
/// the same entry still pastes as plain text into a terminal.
typealias ClipPayload = [[String: Data]]

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

    static func == (lhs: ClipRecord, rhs: ClipRecord) -> Bool {
        lhs.id == rhs.id && lhs.createdAt == rhs.createdAt && lhs.pinned == rhs.pinned
    }

    /// The row's title. A colour's own text is whatever the source application happened
    /// to put alongside it — often nothing useful — so the parsed value reads better.
    var displayTitle: String { colorHex ?? preview }

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
    /// A binary property list — `[[String: Data]]` is already a valid plist object, so
    /// this needs no schema of its own and stays readable with `plutil`.
    static func encode(_ payload: ClipPayload) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
    }

    static func decode(_ data: Data) -> ClipPayload? {
        let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return object as? ClipPayload
    }

    static func byteSize(_ payload: ClipPayload) -> Int {
        payload.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
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

    struct Options {
        var recordImages = true
        var skipConcealed = true
        var skipTransient = true
        var maxItemBytes = 20 * 1024 * 1024
    }

    enum Outcome {
        case captured(ClipPayload, ClipKind, Reduction)
        case ignored(String)
    }

    struct Reduction {
        /// Payload was over the cap and dropped; only metadata survives.
        var oversized = false
        var byteSize = 0
    }

    /// Reads the pasteboard into a payload. Must run on the main thread, where the
    /// pasteboard is read everywhere else in the app.
    static func read(_ pasteboard: NSPasteboard, options: Options) -> Outcome {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return .ignored("empty")
        }

        let allTypes = Set(items.flatMap { $0.types.map(\.rawValue) })

        if options.skipConcealed, !allTypes.isDisjoint(with: concealedTypes) {
            return .ignored("concealed")
        }
        if options.skipTransient, !allTypes.isDisjoint(with: transientTypes) {
            return .ignored("transient")
        }

        let kind = classify(allTypes, items: items)
        if kind == .image, !options.recordImages {
            return .ignored("images disabled")
        }

        var payload: ClipPayload = []
        for item in items {
            var bucket: [String: Data] = [:]
            let types = item.types.map(\.rawValue)
            // A screenshot arrives as both TIFF and PNG of the same picture, and the
            // TIFF is routinely ten times larger. Dropping it costs nothing — every
            // application that accepts an image accepts PNG — and it is the difference
            // between a screenshot fitting under the size cap and being thrown away.
            let dropTIFF = types.contains(NSPasteboard.PasteboardType.png.rawValue)
            for type in types {
                if excludedTypes.contains(type) { continue }
                if dropTIFF, type == NSPasteboard.PasteboardType.tiff.rawValue { continue }
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
                bucket[type] = data
            }
            if !bucket.isEmpty { payload.append(bucket) }
        }

        guard !payload.isEmpty else { return .ignored("no readable types") }

        var reduction = Reduction()
        reduction.byteSize = ClipPayloadCoder.byteSize(payload)
        if reduction.byteSize > options.maxItemBytes {
            reduction.oversized = true
        }
        return .captured(payload, kind, reduction)
    }

    private static func classify(_ types: Set<String>, items: [NSPasteboardItem]) -> ClipKind {
        if types.contains("public.file-url") { return .files }
        if types.contains(NSPasteboard.PasteboardType.png.rawValue)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) {
            return .image
        }
        if types.contains(NSPasteboard.PasteboardType.color.rawValue) { return .color }

        let text = plainText(items) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
           let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "mailto"].contains(scheme) {
            return .url
        }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue) {
            return .richText
        }
        return .text
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
            "public.text",
        ]
        for item in payload {
            for type in candidates {
                if let data = item[type], let string = String(data: data, encoding: .utf8),
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
               let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                return attributed.string
            }
            if let data = item[NSPasteboard.PasteboardType.html.rawValue],
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.html],
                   documentAttributes: nil
               ) {
                return attributed.string
            }
        }
        return nil
    }

    static func fileURLs(from payload: ClipPayload) -> [URL] {
        payload.compactMap { item in
            guard let data = item["public.file-url"],
                  let string = String(data: data, encoding: .utf8)
            else { return nil }
            return URL(string: string)
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
        if let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        // Colours archived by an older producer are not secure-coded, and losing the
        // value over that would be a shame when the class is one we asked for by name.
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(of: NSColor.self, forKey: NSKeyedArchiveRootObjectKey)
    }

    static func image(from payload: ClipPayload) -> NSImage? {
        for item in payload {
            if let data = item[NSPasteboard.PasteboardType.png.rawValue],
               let image = NSImage(data: data) { return image }
            if let data = item[NSPasteboard.PasteboardType.tiff.rawValue],
               let image = NSImage(data: data) { return image }
        }
        return nil
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
