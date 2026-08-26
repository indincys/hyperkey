import XCTest

@testable import Hyper

/// Search has to find things the row cannot show: the preview is 400 characters, so most
/// of what was copied is only reachable through the sidecar text and its romanisations.
final class ClipSearchTests: XCTestCase {
    private func record(
        preview: String,
        kind: ClipKind = .text,
        pinned: Bool = false,
        source: String? = nil,
        id: UUID = UUID()
    ) -> ClipRecord {
        ClipRecord(
            id: id,
            createdAt: Date(),
            kind: kind,
            preview: preview,
            digest: id.uuidString,
            byteSize: preview.utf8.count,
            sourceBundleID: nil,
            sourceName: source,
            pinned: pinned
        )
    }

    // MARK: - Building entries

    func testEmptyTextHasNoEntry() {
        XCTAssertNil(ClipSearch.makeEntry(text: ""))
    }

    func testTextIsCappedButNotDropped() throws {
        let long = String(repeating: "a", count: ClipSearch.maxTextLength + 500)
        let entry = try XCTUnwrap(ClipSearch.makeEntry(text: long))
        XCTAssertEqual(entry.text.count, ClipSearch.maxTextLength)
    }

    func testPureASCIIProducesNoPinyin() throws {
        let entry = try XCTUnwrap(ClipSearch.makeEntry(text: "hello world 123"))
        XCTAssertTrue(entry.pinyin.isEmpty, "romanising Latin text would only cost time")
        XCTAssertTrue(entry.initials.isEmpty)
    }

    func testCJKProducesCompactPinyinAndInitials() throws {
        let entry = try XCTUnwrap(ClipSearch.makeEntry(text: "剪贴板"))
        XCTAssertEqual(entry.pinyin, "jiantieban", "syllable breaks are dropped")
        XCTAssertEqual(entry.initials, "jtb")
    }

    // MARK: - Terms

    func testTermsAreLowercasedAndWhitespaceSeparated() {
        XCTAssertEqual(ClipSearch.terms(from: "  Foo\tBAR \n baz "), ["foo", "bar", "baz"])
        XCTAssertEqual(ClipSearch.terms(from: "   "), [])
    }

    // MARK: - Matching

    func testHitPastThePreviewStillMatches() throws {
        let record = record(preview: "the opening paragraph")
        let entry = try XCTUnwrap(
            ClipSearch.makeEntry(text: "the opening paragraph and then, much later, a needle")
        )
        XCTAssertTrue(ClipSearch.matches(record: record, entry: entry, terms: ["needle"]))
        XCTAssertFalse(ClipSearch.matches(record: record, entry: nil, terms: ["needle"]))
    }

    func testMultipleTermsAreANDed() throws {
        let record = record(preview: "alpha")
        let entry = try XCTUnwrap(ClipSearch.makeEntry(text: "alpha and beta"))
        XCTAssertTrue(ClipSearch.matches(record: record, entry: entry, terms: ["alpha", "beta"]))
        XCTAssertFalse(ClipSearch.matches(record: record, entry: entry, terms: ["alpha", "gamma"]))
    }

    func testSourceNameIsSearchable() {
        let record = record(preview: "nothing relevant", source: "Safari")
        XCTAssertTrue(ClipSearch.matches(record: record, entry: nil, terms: ["safari"]))
        XCTAssertFalse(ClipSearch.matches(record: record, entry: nil, terms: ["ghostty"]))
    }

    func testPinyinMatchesFullCompactAndInitialForms() throws {
        let record = record(preview: "剪贴板")
        let entry = try XCTUnwrap(ClipSearch.makeEntry(text: "剪贴板"))

        XCTAssertTrue(ClipSearch.matches(record: record, entry: entry, terms: ["jiantieban"]))
        XCTAssertTrue(ClipSearch.matches(record: record, entry: entry, terms: ["jiantie"]))
        XCTAssertTrue(ClipSearch.matches(record: record, entry: entry, terms: ["jtb"]))
        XCTAssertTrue(ClipSearch.matches(record: record, entry: entry, terms: ["剪贴"]))
        XCTAssertFalse(ClipSearch.matches(record: record, entry: entry, terms: ["zhongwen"]))
    }

    func testPinyinIsOnlyConsultedForLatinOnlyTerms() throws {
        let record = record(preview: "剪贴板")
        let entry = try XCTUnwrap(ClipSearch.makeEntry(text: "剪贴板"))
        // A term with a digit in it can never be pinyin, so the romanised forms are
        // skipped entirely rather than compared against every CJK entry.
        XCTAssertFalse(ClipSearch.matches(record: record, entry: entry, terms: ["jtb1"]))
    }

    // MARK: - Running a query

    func testFiltersByKindAndPinnedState() {
        let snapshot = ClipSearchSnapshot(
            records: [
                record(preview: "a link", kind: .url, pinned: true),
                record(preview: "some text", kind: .text),
                record(preview: "a picture", kind: .image, pinned: true),
            ],
            index: [:]
        )

        let byKind = ClipSearch.run(
            ClipSearchRequest(terms: [], kind: .url, pinnedOnly: false), in: snapshot
        )
        XCTAssertEqual(byKind.records.map(\.preview), ["a link"])
        XCTAssertTrue(byKind.terms.isEmpty)
        XCTAssertTrue(byKind.contexts.isEmpty)

        let pinned = ClipSearch.run(
            ClipSearchRequest(terms: [], kind: nil, pinnedOnly: true), in: snapshot
        )
        XCTAssertEqual(pinned.records.count, 2)

        let all = ClipSearch.run(
            ClipSearchRequest(terms: [], kind: nil, pinnedOnly: false), in: snapshot
        )
        XCTAssertEqual(all.records.count, 3, "an empty query filters nothing")
    }

    func testContextIsCarriedOnlyForHitsThePreviewCannotShow() throws {
        let visible = record(preview: "needle is right here")
        let hidden = record(preview: "the opening paragraph")
        let entry = try XCTUnwrap(
            ClipSearch.makeEntry(text: "the opening paragraph, and far below it a needle sits")
        )
        let snapshot = ClipSearchSnapshot(
            records: [visible, hidden],
            index: [visible.id: try XCTUnwrap(ClipSearch.makeEntry(text: "needle is right here")),
                    hidden.id: entry]
        )

        let outcome = ClipSearch.run(
            ClipSearchRequest(terms: ["needle"], kind: nil, pinnedOnly: false), in: snapshot
        )
        XCTAssertEqual(outcome.records.count, 2)
        XCTAssertEqual(outcome.terms, ["needle"])
        XCTAssertNil(outcome.contexts[visible.id], "the row already shows the hit")
        let context = try XCTUnwrap(outcome.contexts[hidden.id])
        XCTAssertTrue(context.contains("needle"))
    }

    // MARK: - Highlighting

    func testRangesFindEveryOccurrence() {
        let string = "abc-abc-abc"
        let ranges = ClipSearch.ranges(in: string, terms: ["abc"])
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map { String(string[$0]) }, ["abc", "abc", "abc"])

        // Back-to-back hits are one run to highlight, not several.
        XCTAssertEqual(ClipSearch.ranges(in: "abcabc", terms: ["abc"]).count, 1)
    }

    func testRangesAreMergedAndOrdered() {
        let string = "aaaa"
        let ranges = ClipSearch.ranges(in: string, terms: ["aa", "aaa"])
        XCTAssertEqual(ranges.count, 1, "overlapping hits collapse into one run")
        XCTAssertEqual(String(string[ranges[0]]), "aaaa")

        let sentence = "beta then alpha"
        let ordered = ClipSearch.ranges(in: sentence, terms: ["alpha", "beta"])
        XCTAssertEqual(ordered.map { String(sentence[$0]) }, ["beta", "alpha"])
    }

    func testRangesIgnoreCaseAndDiacritics() {
        let string = "Café"
        let ranges = ClipSearch.ranges(in: string, terms: ["cafe"])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(string[ranges[0]]), "Café")
    }

    func testRangesOnNothingToFind() {
        XCTAssertTrue(ClipSearch.ranges(in: "abc", terms: []).isEmpty)
        XCTAssertTrue(ClipSearch.ranges(in: "", terms: ["a"]).isEmpty)
        XCTAssertTrue(ClipSearch.ranges(in: "abc", terms: ["z"]).isEmpty)
        XCTAssertTrue(ClipSearch.ranges(in: "abc", terms: [""]).isEmpty, "an empty term must not loop")
    }

    func testRangesAreCappedPerTerm() {
        let string = String(repeating: "x", count: 200)
        XCTAssertEqual(ClipSearch.ranges(in: string, terms: ["x"], limit: 5).count, 1,
                       "five adjacent hits merge into one run")
        // The cap is on hits, not on the merged output: spread them out to see it.
        let spread = String(repeating: "x.", count: 200)
        XCTAssertEqual(ClipSearch.ranges(in: spread, terms: ["x"], limit: 5).count, 5)
    }

    // MARK: - Context snippets

    func testContextWindowsAroundTheFirstHit() throws {
        let text = String(repeating: "a", count: 30) + "needle" + String(repeating: "b", count: 30)
        let snippet = try XCTUnwrap(ClipSearch.context(in: text, terms: ["needle"], radius: 5))
        XCTAssertEqual(snippet, "…aaaaaneedlebbbbb…")
    }

    func testContextOmitsEllipsesAtTheEdges() throws {
        let snippet = try XCTUnwrap(ClipSearch.context(in: "needle", terms: ["needle"], radius: 20))
        XCTAssertEqual(snippet, "needle")
    }

    func testContextCollapsesWhitespaceInTheWindow() throws {
        let snippet = try XCTUnwrap(
            ClipSearch.context(in: "one\n\n\ntwo needle three", terms: ["needle"], radius: 40)
        )
        XCTAssertEqual(snippet, "one two needle three")
    }

    func testContextReturnsNilWhenNothingMatches() {
        XCTAssertNil(ClipSearch.context(in: "abc", terms: ["z"]))
        XCTAssertNil(ClipSearch.context(in: "abc", terms: []))
    }
}
