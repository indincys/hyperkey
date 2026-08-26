import Foundation

/// The searchable body of one entry, plus its romanised forms.
///
/// `preview` only holds the first 400 collapsed characters, so anything copied out of a
/// document is unfindable by the part of it that matters. This is the rest of the text,
/// kept next to the payload in `search/<uuid>.txt` and mirrored in memory.
struct ClipSearchEntry: Sendable {
    /// Plain text, capped at `ClipSearch.maxTextLength` characters.
    let text: String
    /// Mandarin pinyin with the syllable breaks removed — "剪贴板" becomes "jiantieban",
    /// which is what someone typing without pauses actually produces. Empty when the
    /// text holds no CJK.
    let pinyin: String
    /// First letter of every syllable: "jtb" for "剪贴板".
    let initials: String
}

/// A prepared query. Splitting once and reusing the terms keeps the per-record work in
/// the filter loop down to substring searches.
struct ClipSearchRequest: Sendable {
    var terms: [String]
    var kind: ClipKind?
    var pinnedOnly: Bool
}

/// Records plus the text index, taken together on the main thread so the actual scan
/// can run anywhere. Both members are copy-on-write, so this costs two retains rather
/// than a copy of the whole history.
struct ClipSearchSnapshot: Sendable {
    var records: [ClipRecord]
    var index: [UUID: ClipSearchEntry]
}

struct ClipSearchOutcome: Sendable {
    var records: [ClipRecord]
    /// Echoed back so the view highlights exactly what this result set was filtered by,
    /// and not whatever has since been typed into the field.
    var terms: [String]
    /// Snippet of surrounding text for rows whose only hit is past the preview.
    var contexts: [UUID: String]
}

enum ClipSearch {
    /// A copied file can be a whole book; indexing all of it would put the history's
    /// entire text in memory. 32K characters is far past where anyone still recognises
    /// what they copied, and keeps a thousand entries inside a few tens of megabytes.
    static let maxTextLength = 32 * 1024

    /// Romanising is linear in the input and only ever helps with the beginning of an
    /// entry, so it looks at a small window rather than the whole 32K.
    static let pinyinSourceLength = 2 * 1024

    // MARK: - Building

    static func makeEntry(text: String) -> ClipSearchEntry? {
        let capped = text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text
        guard !capped.isEmpty else { return nil }
        let romanised = romanise(String(capped.prefix(pinyinSourceLength)))
        return ClipSearchEntry(text: capped, pinyin: romanised.compact, initials: romanised.initials)
    }

    /// Runs `CFStringTransform` twice: Mandarin-Latin produces tone marks, which nobody
    /// types, so a second pass strips them back down to plain ASCII.
    private static func romanise(_ text: String) -> (compact: String, initials: String) {
        guard text.unicodeScalars.contains(where: isCJK) else { return ("", "") }

        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

        var compact = ""
        var initials = ""
        var atSyllableStart = true
        for scalar in (mutable as String).lowercased().unicodeScalars {
            guard scalar.value >= 97, scalar.value <= 122 else {
                atSyllableStart = true
                continue
            }
            if atSyllableStart {
                initials.unicodeScalars.append(scalar)
                atSyllableStart = false
            }
            compact.unicodeScalars.append(scalar)
        }
        return (compact, initials)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,  // extension A
             0x4E00...0x9FFF,  // unified
             0xF900...0xFAFF,  // compatibility
             0x20000...0x2FA1F:  // extensions B and beyond
            return true
        default:
            return false
        }
    }

    // MARK: - Query

    /// Whitespace-separated words, matched with AND. Typing more never widens the
    /// result set, which is the behaviour that makes narrowing down feel predictable.
    static func terms(from query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    }

    /// The one comparison every search path uses: case- and accent-insensitive, so
    /// "cafe" finds "Café" and a query never has to match the exact keystrokes.
    static func firstRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        firstRange(of: needle, in: haystack) != nil
    }

    /// Pinyin only makes sense for a query that could *be* pinyin. Without this, "png"
    /// would run a pinyin comparison against every CJK entry in the history.
    private static func isLatinOnly(_ term: String) -> Bool {
        guard !term.isEmpty else { return false }
        return term.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 }
    }

    static func matches(record: ClipRecord, entry: ClipSearchEntry?, terms: [String]) -> Bool {
        for term in terms {
            if contains(record.preview, term) { continue }
            if let source = record.sourceName, contains(source, term) { continue }
            if let entry {
                if contains(entry.text, term) { continue }
                if isLatinOnly(term) {
                    if !entry.pinyin.isEmpty, entry.pinyin.contains(term) { continue }
                    if !entry.initials.isEmpty, entry.initials.contains(term) { continue }
                }
            }
            return false
        }
        return true
    }

    // MARK: - Running

    static func run(_ request: ClipSearchRequest, in snapshot: ClipSearchSnapshot) -> ClipSearchOutcome {
        var result = snapshot.records
        if request.pinnedOnly { result = result.filter(\.pinned) }
        if let kind = request.kind { result = result.filter { $0.kind == kind } }

        guard !request.terms.isEmpty else {
            return ClipSearchOutcome(records: result, terms: [], contexts: [:])
        }

        var contexts: [UUID: String] = [:]
        result = result.filter { record in
            let entry = snapshot.index[record.id]
            guard matches(record: record, entry: entry, terms: request.terms) else { return false }
            // A hit buried past the preview is invisible in the row — the label would
            // show text with nothing highlighted in it and look like a false positive.
            // Carrying a snippet lets the row explain why it is in the list.
            // The hit's position is found once and handed to `context`, rather than
            // scanning the same 32K of text a second time to answer where it was.
            if let entry,
               let hidden = request.terms.first(where: { !contains(record.preview, $0) }),
               let hit = firstRange(of: hidden, in: entry.text),
               let snippet = context(in: entry.text, around: hit) {
                contexts[record.id] = snippet
            }
            return true
        }
        return ClipSearchOutcome(records: result, terms: request.terms, contexts: contexts)
    }

    // MARK: - Highlighting

    /// Every occurrence of any term, merged and in order, so a caller can walk the
    /// string once. Capped per term because highlighting the thousandth "the" in a
    /// pasted chapter helps nobody and costs a run of attributes each.
    static func ranges(in string: String, terms: [String], limit: Int = 80) -> [Range<String.Index>] {
        guard !terms.isEmpty, !string.isEmpty else { return [] }

        var found: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var cursor = string.startIndex
            var count = 0
            while count < limit, cursor < string.endIndex,
                  let hit = string.range(
                      of: term,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: cursor..<string.endIndex
                  ) {
                found.append(hit)
                count += 1
                cursor = hit.upperBound > hit.lowerBound
                    ? hit.upperBound
                    : string.index(after: hit.lowerBound)
            }
        }
        guard !found.isEmpty else { return [] }

        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [found[0]]
        for range in found.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A one-line window around the first hit, with ellipses where text was cut off.
    static func context(in text: String, terms: [String], radius: Int = 20) -> String? {
        var earliest: Range<String.Index>?
        for term in terms where !term.isEmpty {
            guard let hit = firstRange(of: term, in: text) else { continue }
            if earliest == nil || hit.lowerBound < earliest!.lowerBound { earliest = hit }
        }
        guard let hit = earliest else { return nil }
        return context(in: text, around: hit, radius: radius)
    }

    /// The same window, for a caller that already knows where the hit is — the search
    /// loop does, and finding it again is a second pass over the whole entry.
    static func context(
        in text: String, around hit: Range<String.Index>, radius: Int = 20
    ) -> String? {
        let start = text.index(hit.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: radius, limitedBy: text.endIndex)
            ?? text.endIndex
        let slice = collapsingWhitespace(text[start..<end])
        guard !slice.isEmpty else { return nil }

        return (start > text.startIndex ? "…" : "") + slice + (end < text.endIndex ? "…" : "")
    }

    /// Runs of whitespace squeezed to one space, and the ends trimmed.
    ///
    /// Hand-written rather than `replacingOccurrences(of: "\\s+", options:
    /// .regularExpression)`: that call compiles the pattern afresh every time, and this
    /// runs once per matching row of a search — a hundred regular expressions built and
    /// thrown away per keystroke, for a substitution a single walk does.
    private static func collapsingWhitespace(_ slice: Substring) -> String {
        var out = ""
        out.reserveCapacity(slice.count)
        var pendingSpace = false
        for character in slice {
            guard !character.isWhitespace else {
                // Held rather than written, so a run at the very end leaves nothing
                // behind — which is what the trim used to do.
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out
    }
}
