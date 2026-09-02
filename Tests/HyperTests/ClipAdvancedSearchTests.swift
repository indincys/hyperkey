import Foundation
import XCTest

@testable import Hyper

final class ClipAdvancedSearchTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeStore(root: URL? = nil) -> ClipStore {
        let location = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-advanced-search-\(UUID().uuidString)", isDirectory: true)
        if root == nil { roots.append(location) }
        let store = ClipStore(root: location)
        let loaded = expectation(description: "store loaded")
        store.whenLoaded { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        return store
    }

    private func insertion(_ text: String) -> ClipStore.Insertion {
        let payload: ClipPayload = [["public.utf8-plain-text": Data(text.utf8)]]
        return ClipStore.Insertion(
            payload: payload, kind: .text, oversized: false,
            byteSize: text.utf8.count, sourceBundleID: "com.example.editor",
            sourceName: "Editor"
        )
    }

    private func record(
        _ preview: String,
        kind: ClipKind = .text,
        app: String? = nil,
        pinned: Bool = false,
        age: TimeInterval = 0,
        id: UUID = UUID()
    ) -> ClipRecord {
        ClipRecord(
            id: id, createdAt: Date(timeIntervalSince1970: 2_000_000_000 - age),
            kind: kind, preview: preview, digest: id.uuidString,
            byteSize: preview.utf8.count, sourceBundleID: nil, sourceName: app,
            pinned: pinned
        )
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func testParserSupportsFieldsPhrasesNegationAndImplicitAND() throws {
        let parsed = try ClipQueryParser.parse(
            #""quarterly plan" app:"Google Chrome" type:text after:2026-01-02 before:2026-12-31 is:pinned -is:queued -draft"#
        )

        XCTAssertEqual(parsed.textTerms.map(\.value), ["quarterly plan", "draft"])
        XCTAssertEqual(parsed.textTerms.map(\.negated), [false, true])
        XCTAssertEqual(parsed.appTerms.map(\.value), ["google chrome"])
        XCTAssertEqual(parsed.kinds, [.text])
        XCTAssertEqual(parsed.pinned, true)
        XCTAssertEqual(parsed.queued, false)
        XCTAssertNotNil(parsed.after)
        XCTAssertNotNil(parsed.before)
        XCTAssertEqual(parsed.highlightTerms, ["quarterly plan"])
    }

    func testParserReturnsLocatedErrorsInsteadOfSilentlyChangingMeaning() {
        XCTAssertThrowsError(try ClipQueryParser.parse(#"app:"unterminated"#)) { error in
            let issue = error as? ClipQueryParseError
            XCTAssertEqual(issue?.position, 4)
            XCTAssertTrue(issue?.message.contains("引号") == true)
        }
        XCTAssertThrowsError(try ClipQueryParser.parse("type:spreadsheet"))
        XCTAssertThrowsError(try ClipQueryParser.parse("before:yesterday"))
        XCTAssertThrowsError(try ClipQueryParser.parse("is:maybe"))
        XCTAssertThrowsError(try ClipQueryParser.parse("after:2026-12-31 before:2026-01-01"))
    }

    func testIndexedQueryCombinesMetadataPinyinFuzzyPhraseAndNegativeTerms() throws {
        let chinese = record("剪贴板专业工作流", app: "Safari", pinned: true)
        let fuzzy = record("quarterly planning document", app: "Google Chrome")
        let excluded = record("quarterly planning draft", app: "Google Chrome")
        let records = [excluded, fuzzy, chinese]
        let entries = Dictionary(uniqueKeysWithValues: records.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview)!)
        })
        let index = ClipSearchIndex.build(records: records, entries: entries)
        let snapshot = ClipSearchSnapshot(
            records: records, index: entries, invertedIndex: index,
            queuedIDs: [fuzzy.id]
        )

        let pinyin = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("jiantieban is:pinned")),
            in: snapshot
        )
        XCTAssertEqual(pinyin.records.map(\.id), [chinese.id])

        let advanced = ClipSearch.run(
            ClipSearchRequest(
                query: try ClipQueryParser.parse(#""quarterly planning" -draft is:queued"#)
            ),
            in: snapshot
        )
        XCTAssertEqual(advanced.records.map(\.id), [fuzzy.id])

        let typo = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("quaterly")), in: snapshot
        )
        XCTAssertEqual(Set(typo.records.map(\.id)), [fuzzy.id, excluded.id])
    }

    func testAdvancedQueryFallsBackToCompleteVerificationBeforeIndexIsReady() throws {
        let row = record("preview does not contain it")
        let entry = ClipSearch.makeEntry(text: "a hidden startup needle")!
        let snapshot = ClipSearchSnapshot(records: [row], index: [row.id: entry])
        let result = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("needle")), in: snapshot
        )
        XCTAssertEqual(result.records.map(\.id), [row.id])
    }

    func testCandidateIndexIsAStrictSupersetAcrossExactPartialFuzzyAndUnindexableTerms() throws {
        let boundedUnicode = try XCTUnwrap(
            ClipSearch.makeEntry(text: String(repeating: "🔥", count: 40_000))
        )
        XCTAssertLessThanOrEqual(boundedUnicode.text.utf8.count, ClipSearch.maxTextLength)
        let long = String(repeating: "a", count: 150) + "tailmarker"
        let values = [
            "needle", "needlework", "hayneedlehay", "nedle", long, "symbols 🔥 only",
            "professionalclipboard", "Éclair Über",
        ]
        let rows = values.map { record(String($0.prefix(400))) }
        let entries = Dictionary(uniqueKeysWithValues: zip(rows, values).map {
            ($0.0.id, ClipSearch.makeEntry(text: $0.1)!)
        })
        let snapshot = ClipSearchSnapshot(
            records: rows, index: entries,
            invertedIndex: ClipSearchIndex.build(records: rows, entries: entries)
        )

        let needle = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("needle")), in: snapshot
        )
        XCTAssertEqual(Set(needle.records.map(\.id)), Set(rows.prefix(4).map(\.id)))
        let suffix = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("tailmarker")), in: snapshot
        )
        XCTAssertEqual(suffix.records.map(\.id), [rows[4].id])
        let punctuation = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("🔥")), in: snapshot
        )
        XCTAssertEqual(punctuation.records.map(\.id), [rows[5].id])
        let oneEdit = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("profesionalclipboard")),
            in: snapshot
        )
        XCTAssertEqual(oneEdit.records.map(\.id), [rows[6].id])
        let twoEdits = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("professonalclipbord")),
            in: snapshot
        )
        XCTAssertEqual(twoEdits.records.map(\.id), [rows[6].id])
        let unicode = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("eclair")), in: snapshot
        )
        XCTAssertEqual(unicode.records.map(\.id), [rows[7].id])
    }

    func testBudgetAccountsForBodiesPostingsAndOverflowWithoutEverCrossingLimit() throws {
        let budget = 2 * 1024 * 1024
        var rows: [ClipRecord] = []
        var entries: [UUID: ClipSearchEntry] = [:]
        for document in 0..<220 {
            let body = (0..<350).map { "unique_\(document)_\($0)" }.joined(separator: " ")
            let row = record(String(body.prefix(400)))
            rows.append(row)
            entries[row.id] = ClipSearch.makeEntry(text: body)!
        }
        let index = ClipSearchIndex.build(
            records: rows, entries: entries, maximumResidentBytes: budget
        )
        XCTAssertLessThanOrEqual(index.estimatedResidentBytes, budget)
        XCTAssertGreaterThan(index.accountedBodyBytes, 1_000_000)
        XCTAssertGreaterThan(index.postingCount, 0)
        XCTAssertGreaterThan(index.overflowDocumentCount, 0)
        XCTAssertGreaterThanOrEqual(
            index.estimatedResidentBytes,
            index.accountedBodyBytes + index.postingCount * ClipSearchIndex.minimumPostingBytes
        )

        let snapshot = ClipSearchSnapshot(records: rows, index: entries, invertedIndex: index)
        let result = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("unique_219_349")), in: snapshot
        )
        XCTAssertEqual(result.records.map(\.id), [rows[219].id])
    }

    func testRunningLexiconExpansionCancelsAndDoesNotBlockNewExactQuery() throws {
        var rows: [ClipRecord] = []
        var entries: [UUID: ClipSearchEntry] = [:]
        for document in 0..<700 {
            let body = (0..<120).map { "lexicon\(document)x\($0)" }.joined(separator: " ")
                + (document == 699 ? " finalneedle" : "")
            let row = record(String(body.prefix(400)))
            rows.append(row)
            entries[row.id] = ClipSearch.makeEntry(text: body)!
        }
        let index = ClipSearchIndex.build(records: rows, entries: entries)
        let token = ClipSearchCancellationToken()
        let cancelled = expectation(description: "lexicon scan cancelled")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = index.candidates(for: "zzzzzzzz", cancellation: token)
            XCTAssertTrue(result.cancelled)
            cancelled.fulfill()
        }
        // Cancellation races a live scan rather than waiting until after its normal
        // sub-millisecond completion on fast machines.
        DispatchQueue.global().async { token.cancel() }
        wait(for: [cancelled], timeout: 0.25)

        let began = ProcessInfo.processInfo.systemUptime
        let exact = index.candidates(for: "finalneedle")
        XCTAssertTrue(exact.ids.contains(rows[699].id), "candidate set is a verifier superset")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.075)
    }

    func testProductionColdRestoreStreamsSixteenSlotsUnderTotalMemoryCap() throws {
        let runtimeBaseline = Self.physicalFootprint()
        var rows: [ClipRecord] = []
        var entries: [UUID: ClipSearchEntry] = [:]
        rows.reserveCapacity(5_000)
        entries.reserveCapacity(5_000)
        let filler = String(repeating: "x", count: 32_380)
        for document in 0..<5_000 {
            let body = "\(document)-" + filler
            let row = record(String(body.prefix(400)))
            rows.append(row)
            entries[row.id] = ClipSearch.makeEntry(text: body)!
        }
        let recordsBySlot = Dictionary(grouping: rows) { ClipSearchIndex.slot(for: $0.id) }
        XCTAssertEqual(recordsBySlot.count, ClipSearchIndex.segmentCount)
        let fixtureFootprint = Self.physicalFootprint()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-search-production-cold-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = ClipboardVault(
            provider: EphemeralClipboardVaultKeyProvider(
                scope: "search-production-cold-\(UUID().uuidString)"
            )
        )
        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: false, hasLegacyPlaintext: false), .ready
        )

        try autoreleasepool {
            let hot = ClipSearchIndex.build(records: rows, entries: entries)
            XCTAssertEqual(hot.documentIDs.count, rows.count)
            for slot in 0..<ClipSearchIndex.segmentCount {
                let context = String(format: "search-index/segment-%02d.json", slot)
                let sealed = try vault.seal(
                    hot.encodedSegment(slot: slot), context: context
                )
                try sealed.write(
                    to: root.appendingPathComponent(String(format: "segment-%02d.json", slot)),
                    options: .atomic
                )
            }
        }
        _ = malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let coldProcessBaseline = Self.physicalFootprint()

        let sampleLock = NSLock()
        var keepSampling = true
        var peak = Self.physicalFootprint()
        let sampleDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while sampleLock.withLock({ keepSampling }) {
                let footprint = Self.physicalFootprint()
                sampleLock.withLock { peak = max(peak, footprint) }
                usleep(2_000)
            }
            sampleDone.signal()
        }
        let restored = ClipStore.restorePersistedSearchIndex(
            recordsBySlot: recordsBySlot, entries: entries,
            readProtectedSegment: { slot in
                let context = String(format: "search-index/segment-%02d.json", slot)
                let stored = try Data(
                    contentsOf: root.appendingPathComponent(
                        String(format: "segment-%02d.json", slot)
                    ), options: .mappedIfSafe
                )
                return try vault.open(stored, context: context)
            }
        )
        sampleLock.withLock { keepSampling = false }
        XCTAssertEqual(sampleDone.wait(timeout: .now() + 2), .success)
        let cold = try XCTUnwrap(restored)
        XCTAssertEqual(cold.documentIDs.count, rows.count)
        let steady = Self.physicalFootprint()
        let measuredPeak = sampleLock.withLock { peak }
        let fixtureBytes = fixtureFootprint >= runtimeBaseline
            ? fixtureFootprint - runtimeBaseline : 0
        let coldSteadyBytes = steady >= coldProcessBaseline
            ? steady - coldProcessBaseline : 0
        let coldPeakBytes = measuredPeak >= coldProcessBaseline
            ? measuredPeak - coldProcessBaseline : 0
        let structuralBytes = UInt64(max(
            0, cold.estimatedResidentBytes - cold.accountedBodyBytes
        ))
        // Fixture bodies remain fully counted. Only allocator residue from constructing
        // and sealing the prerequisite hot files in this same XCTest process is removed;
        // a real cold launch never contains that setup phase.
        // Retained setup pages are reused by cold allocations, so a raw delta could
        // misleadingly show less than the live packed filter table. Floor both readings
        // at the index's conservative structural charge while keeping the physical body
        // fixture in full.
        let totalSteady = fixtureBytes + max(coldSteadyBytes, structuralBytes)
        let totalPeak = fixtureBytes + max(coldPeakBytes, structuralBytes)
        print(
            "SEARCH_PRODUCTION_COLD_STREAM runtime=\(runtimeBaseline) "
                + "fixture=\(fixtureFootprint) coldBaseline=\(coldProcessBaseline) "
                + "steady=\(steady) peak=\(measuredPeak) totalSteady=\(totalSteady) "
                + "totalPeak=\(totalPeak) structural=\(structuralBytes) "
                + "hardCap=\(ClipSearchIndex.maximumResidentBytes)"
        )
        XCTAssertLessThanOrEqual(totalSteady, UInt64(ClipSearchIndex.maximumResidentBytes))
        XCTAssertLessThanOrEqual(totalPeak, UInt64(ClipSearchIndex.maximumResidentBytes))
    }

    func testParserIntersectsRepeatedDatesRejectsSingletonConflictsAndKeepsURLsLiteral() throws {
        let parsed = try ClipQueryParser.parse(
            "after:2026-01-01 after:2026-02-01 before:2026-12-31 before:2026-11-01"
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(formatter.string(from: try XCTUnwrap(parsed.after)), "2026-02-01")
        XCTAssertEqual(formatter.string(from: try XCTUnwrap(parsed.before)), "2026-11-01")
        XCTAssertThrowsError(try ClipQueryParser.parse("is:pinned -is:pinned"))
        XCTAssertThrowsError(try ClipQueryParser.parse("type:text type:image"))

        let url = try ClipQueryParser.parse(#""https://example.com/a:b?q=x""#)
        XCTAssertEqual(url.textTerms.map(\.value), ["https://example.com/a:b?q=x"])
    }

    func testOutcomeExplainsPinyinFuzzyAndLiteralMatchesForUI() throws {
        let rows = [record("剪贴板"), record("quarterly report"), record("literal needle")]
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview)!)
        })
        let snapshot = ClipSearchSnapshot(
            records: rows, index: entries,
            invertedIndex: ClipSearchIndex.build(records: rows, entries: entries)
        )
        let pinyin = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("jiantieban")), in: snapshot
        )
        XCTAssertEqual(pinyin.matchExplanations[rows[0].id]?.first?.kind, .pinyin)
        let fuzzy = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("quaterly")), in: snapshot
        )
        XCTAssertEqual(fuzzy.matchExplanations[rows[1].id]?.first?.kind, .fuzzy)
        let literal = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("needle")), in: snapshot
        )
        XCTAssertNotNil(literal.matchExplanations[rows[2].id]?.first?.utf16Range)
    }

    func testSegmentRoundTripRejectsWrongVersionOrDigestAndCanBeRebuilt() throws {
        let row = record("persistent needle")
        let entry = ClipSearch.makeEntry(text: row.preview)!
        let index = ClipSearchIndex.build(records: [row], entries: [row.id: entry])
        let slot = ClipSearchIndex.slot(for: row.id)
        let encoded = try index.encodedSegment(slot: slot)
        let decoded = try ClipSearchIndex.decodeSegment(encoded, expectedSlot: slot)
        XCTAssertEqual(decoded.documentCount, 1)
        XCTAssertTrue(decoded.contains(recordID: row.id, recordDigest: row.digest, entry: entry))

        var corrupt = encoded
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xff
        XCTAssertThrowsError(try ClipSearchIndex.decodeSegment(corrupt, expectedSlot: slot))
    }

    func testBudgetTruncatedSegmentsRestoreAsAuthenticatedSubsetsWithoutRebuildLoop() throws {
        let ids = (0..<8).map { offset in
            UUID(uuidString: String(format: "00%02X0000-0000-4000-8000-000000000000", offset))!
        }
        let rows = ids.enumerated().map { offset, id in
            record("budgeted-hidden-needle-\(offset)", id: id)
        }
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview)!)
        })
        let slot = try XCTUnwrap(rows.first.map { ClipSearchIndex.slot(for: $0.id) })
        XCTAssertTrue(rows.allSatisfy { ClipSearchIndex.slot(for: $0.id) == slot })
        let recordsBySlot = [slot: rows]

        // The production builder may legitimately stop before representing every
        // record when its global resident budget is exhausted. Both a non-empty subset
        // and an empty segment are valid persisted accelerators; the verifier still owns
        // correctness for every unrepresented record.
        let partial = ClipSearchIndex.build(
            records: rows, entries: entries, maximumResidentBytes: 96 * 1024
        )
        XCTAssertGreaterThan(partial.documentIDs.count, 0)
        XCTAssertLessThan(partial.documentIDs.count, rows.count)
        let partialBytes = try partial.encodedSegment(slot: slot)

        let restoredPartial = try XCTUnwrap(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: recordsBySlot, entries: entries,
            readProtectedSegment: { requestedSlot in
                XCTAssertEqual(requestedSlot, slot)
                return partialBytes
            }
        ))
        XCTAssertEqual(restoredPartial.documentIDs, partial.documentIDs)
        let missing = try XCTUnwrap(rows.first { !restoredPartial.documentIDs.contains($0.id) })
        let partialSearch = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse(missing.preview)),
            in: ClipSearchSnapshot(
                records: rows, index: entries, invertedIndex: restoredPartial
            )
        )
        XCTAssertEqual(partialSearch.records.map(\.id), [missing.id])

        // A second cold adoption of the identical bytes must remain a restore, rather
        // than falling into a global rebuild/rewrite cycle on every launch.
        XCTAssertNotNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: recordsBySlot, entries: entries,
            readProtectedSegment: { _ in partialBytes }
        ))

        let empty = ClipSearchIndex.build(
            records: rows, entries: entries, maximumResidentBytes: 64 * 1024
        )
        XCTAssertTrue(empty.documentIDs.isEmpty)
        let emptyBytes = try empty.encodedSegment(slot: slot)
        let restoredEmpty = try XCTUnwrap(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: recordsBySlot, entries: entries,
            readProtectedSegment: { _ in emptyBytes }
        ))
        XCTAssertTrue(restoredEmpty.documentIDs.isEmpty)
        let emptySearch = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse(rows[7].preview)),
            in: ClipSearchSnapshot(records: rows, index: entries, invertedIndex: restoredEmpty)
        )
        XCTAssertEqual(emptySearch.records.map(\.id), [rows[7].id])
        XCTAssertNotNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: recordsBySlot, entries: entries,
            readProtectedSegment: { _ in emptyBytes }
        ))
    }

    func testSubsetRestoreStillRejectsAlienIDsAndDigestMismatch() throws {
        let expectedID = UUID(uuidString: "00100000-0000-4000-8000-000000000000")!
        let alienID = UUID(uuidString: "00200000-0000-4000-8000-000000000000")!
        let expected = record("expected body", id: expectedID)
        let alien = record("alien body", id: alienID)
        let entries = [
            expected.id: ClipSearch.makeEntry(text: expected.preview)!,
            alien.id: ClipSearch.makeEntry(text: alien.preview)!,
        ]
        let slot = ClipSearchIndex.slot(for: expected.id)
        XCTAssertEqual(ClipSearchIndex.slot(for: alien.id), slot)

        let withAlien = ClipSearchIndex.build(
            records: [expected, alien], entries: entries
        )
        let alienBytes = try withAlien.encodedSegment(slot: slot)
        XCTAssertNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: [slot: [expected]], entries: entries,
            readProtectedSegment: { _ in alienBytes }
        ))

        let valid = ClipSearchIndex.build(records: [expected], entries: entries)
        let validBytes = try valid.encodedSegment(slot: slot)
        var changed = expected
        changed.digest = "different-record-digest"
        XCTAssertNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: [slot: [changed]], entries: entries,
            readProtectedSegment: { _ in validBytes }
        ))

        var changedEntries = entries
        changedEntries[expected.id] = ClipSearch.makeEntry(text: "different entry body")!
        XCTAssertNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: [slot: [expected]], entries: changedEntries,
            readProtectedSegment: { _ in validBytes }
        ))

        var wrongSlot = try ClipSearchIndex.decodeSegment(validBytes, expectedSlot: slot)
        wrongSlot.slot = (slot + 1) % ClipSearchIndex.segmentCount
        let wrongSlotBytes = try ClipSearchIndex.encodedSegment(wrongSlot)
        XCTAssertNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: [slot: [expected]], entries: entries,
            readProtectedSegment: { _ in wrongSlotBytes }
        ))

        var wrongVersion = try ClipSearchIndex.decodeSegment(validBytes, expectedSlot: slot)
        wrongVersion.version = ClipSearchIndex.formatVersion + 1
        let wrongVersionBytes = try ClipSearchIndex.encodedSegment(wrongVersion)
        XCTAssertNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: [slot: [expected]], entries: entries,
            readProtectedSegment: { _ in wrongVersionBytes }
        ))
        XCTAssertNil(ClipStore.restorePersistedSearchIndex(
            recordsBySlot: [slot: [expected]], entries: entries,
            readProtectedSegment: { _ in Data(#"{"version":"broken"}"#.utf8) }
        ))
    }

    func testProductionAdoptionDoesNotRewritePermanentlyBudgetOmittedRecordAcrossLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-search-exhausted-launch-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = (0..<8).map { offset in
            UUID(uuidString: String(format: "00%02X1000-0000-4000-8000-000000000000", offset))!
        }
        let rows = ids.enumerated().map { offset, id in
            record("permanent-budget-missing-needle-\(offset)", id: id)
        }
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview)!)
        })
        let slot = ClipSearchIndex.slot(for: rows[0].id)
        XCTAssertTrue(rows.allSatisfy { ClipSearchIndex.slot(for: $0.id) == slot })
        let budget = 96 * 1024
        let generation = ClipSearchIndex.build(
            records: rows, entries: entries, maximumResidentBytes: budget
        )
        XCTAssertGreaterThan(generation.documentIDs.count, 0)
        XCTAssertLessThan(generation.documentIDs.count, rows.count)
        let missing = try XCTUnwrap(rows.first { !generation.documentIDs.contains($0.id) })

        // A stale document is different from a never-represented one: removing its old
        // persisted body is a real mutation even if the replacement is too large to fit.
        let staleID = try XCTUnwrap(generation.documentIDs.first)
        let staleRecord = try XCTUnwrap(rows.first { $0.id == staleID })
        var oversizedEntries = entries
        oversizedEntries[staleID] = ClipSearch.makeEntry(
            text: String(repeating: "oversized-stale-body-", count: 2_000)
        )!
        let staleReconciliation = ClipStore.reconcileRestoredSearchIndex(
            generation, records: [staleRecord], entries: oversizedEntries
        )
        XCTAssertTrue(staleReconciliation.dirtySlots.contains(slot))
        XCTAssertFalse(staleReconciliation.index.documentIDs.contains(staleID))

        let vault = ClipboardVault(
            provider: EphemeralClipboardVaultKeyProvider(
                scope: "search-exhausted-launch-\(UUID().uuidString)"
            )
        )
        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: false, hasLegacyPlaintext: false), .ready
        )
        let relative = String(format: "search-index/segment-%02d.json", slot)
        let context = ClipboardVault.storageContext(relativePath: relative)
        let segmentURL = root.appendingPathComponent(String(format: "segment-%02d.json", slot))
        let initialCiphertext = try vault.seal(
            generation.encodedSegment(slot: slot), context: context
        )
        try initialCiphertext.write(to: segmentURL, options: .atomic)
        let sentinelDate = Date(timeIntervalSince1970: 978_307_200)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinelDate], ofItemAtPath: segmentURL.path
        )

        var persistenceWrites = 0
        func launchAndAdopt() throws -> ClipSearchIndex {
            let ciphertext = try Data(contentsOf: segmentURL)
            let restored = try XCTUnwrap(ClipStore.restorePersistedSearchIndex(
                recordsBySlot: [slot: rows], entries: entries,
                maximumResidentBytes: budget,
                readProtectedSegment: { requestedSlot in
                    XCTAssertEqual(requestedSlot, slot)
                    return try vault.open(ciphertext, context: context)
                }
            ))
            let reconciled = ClipStore.reconcileRestoredSearchIndex(
                restored, records: rows, entries: entries
            )
            XCTAssertFalse(reconciled.index.documentIDs.contains(missing.id))
            let outcome = ClipSearch.run(
                ClipSearchRequest(query: try ClipQueryParser.parse(missing.preview)),
                in: ClipSearchSnapshot(
                    records: rows, index: entries, invertedIndex: reconciled.index
                )
            )
            XCTAssertEqual(outcome.records.map(\.id), [missing.id])
            if reconciled.dirtySlots.contains(slot) {
                persistenceWrites += 1
                let replacement = try vault.seal(
                    reconciled.index.encodedSegment(slot: slot), context: context
                )
                try replacement.write(to: segmentURL, options: .atomic)
            }
            return reconciled.index
        }

        _ = try launchAndAdopt()
        let afterFirstCiphertext = try Data(contentsOf: segmentURL)
        let afterFirstDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: segmentURL.path)[.modificationDate]
                as? Date
        )
        XCTAssertEqual(afterFirstCiphertext, initialCiphertext)
        XCTAssertEqual(afterFirstDate, sentinelDate)

        _ = try launchAndAdopt()
        let afterSecondCiphertext = try Data(contentsOf: segmentURL)
        let afterSecondDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: segmentURL.path)[.modificationDate]
                as? Date
        )
        XCTAssertEqual(persistenceWrites, 0)
        XCTAssertEqual(afterSecondCiphertext, afterFirstCiphertext)
        XCTAssertEqual(afterSecondDate, afterFirstDate)
    }

    func testSavedFiltersUseVersionedStrictModelAndStableOrdering() throws {
        var filters = SmartFilterStore.empty
        let first = filters.save(name: "工作", query: "app:Safari is:pinned")
        let second = filters.save(name: "队列", query: "is:queued")
        XCTAssertEqual(filters.filters.map(\.id), [first.id, second.id])

        let data = try filters.encoded()
        XCTAssertEqual(try SmartFilterStore.decode(data).filters, filters.filters)
        var wrongVersion = data
        let text = String(data: wrongVersion, encoding: .utf8)!
            .replacingOccurrences(of: #""version":2"#, with: #""version":999"#)
        wrongVersion = Data(text.utf8)
        XCTAssertThrowsError(try SmartFilterStore.decode(wrongVersion))
    }

    func testStorePersistsAuthenticatedSegmentsAndRebuildsOnlyDerivedDamage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-search-segment-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        var store: ClipStore? = makeStore(root: root)
        let row = store!.insert(insertion("body with a durable needle"))
        XCTAssertTrue(store!.drainPendingWrites(timeout: 5))

        let slot = ClipSearchIndex.slot(for: row.id)
        let segmentURL = root.appendingPathComponent(
            String(format: "search-index/segment-%02d.json", slot)
        )
        let sealed = try Data(contentsOf: segmentURL)
        XCTAssertTrue(ClipboardVault.isSealed(sealed))
        XCTAssertNil(String(data: sealed, encoding: .utf8)?.range(of: "needle"))

        var damaged = sealed
        damaged[damaged.index(before: damaged.endIndex)] ^= 0x01
        try damaged.write(to: segmentURL, options: .atomic)
        store = nil

        store = makeStore(root: root)
        let searchReady = expectation(description: "search rebuilt")
        store!.onSearchIndexLoaded = { searchReady.fulfill() }
        wait(for: [searchReady], timeout: 5)
        XCTAssertEqual(store!.search("needle", kind: nil, pinnedOnly: false).map(\.id), [row.id])
        XCTAssertTrue(store!.drainPendingWrites(timeout: 5))
        XCTAssertTrue(ClipboardVault.isSealed(try Data(contentsOf: segmentURL)))
    }

    func testSavedFiltersAreValidatedAndSealedByStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-smart-filter-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let store = makeStore(root: root)
        let saved = try store.saveSmartFilter(name: "Safari pins", query: "app:Safari is:pinned")
        XCTAssertEqual(store.smartFilters.filters.map(\.id), [saved.id])
        let bytes = try Data(contentsOf: root.appendingPathComponent("smart-filters.json"))
        XCTAssertTrue(ClipboardVault.isSealed(bytes))
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "Safari"))
        XCTAssertThrowsError(try store.saveSmartFilter(name: "Broken", query: "before:soon"))
        XCTAssertEqual(store.smartFilters.filters.map(\.id), [saved.id])
    }

    func testSmartFilterLoadHasDeterministicCompletionEvenOnBlockedLoadQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-smart-filter-load-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        var first: ClipStore? = makeStore(root: root)
        _ = try first!.saveSmartFilter(name: "Slow disk", query: "is:pinned")
        first = nil

        let loadQueue = DispatchQueue(label: "hyper.tests.smart-filter.slow")
        loadQueue.suspend()
        let store = ClipStore(root: root, loadQueue: loadQueue)
        var completed = false
        let ready = expectation(description: "smart filters loaded")
        store.whenSmartFiltersLoaded {
            completed = true
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(store.smartFilters.filters.map(\.name), ["Slow disk"])
            ready.fulfill()
        }
        XCTAssertFalse(completed)
        loadQueue.resume()
        wait(for: [ready], timeout: 5)

        var immediate = false
        store.whenSmartFiltersLoaded { immediate = true }
        XCTAssertTrue(immediate)
    }

    func testLatestSearchSegmentEpochWinsAndInsertionDoesNotEncodeOnMainThread() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-segment-epoch-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        var store: ClipStore? = makeStore(root: root)
        let text = (0..<1_800).map { "token\($0)" }.joined(separator: " ")
        let began = ProcessInfo.processInfo.systemUptime
        let row = store!.insert(insertion(text))
        let mainElapsed = ProcessInfo.processInfo.systemUptime - began
        XCTAssertLessThan(mainElapsed, 0.030, "segment JSON encoding must not run on main")
        XCTAssertNotNil(store!.updateText(id: row.id, newText: "final epoch marker"))
        XCTAssertTrue(store!.drainPendingWrites(timeout: 5))

        let segmentURL = root.appendingPathComponent(
            String(
                format: "search-index/segment-%02d.json",
                ClipSearchIndex.slot(for: row.id)
            )
        )
        let sealed = try Data(contentsOf: segmentURL)
        XCTAssertTrue(ClipboardVault.isSealed(sealed))
        store = nil
        store = makeStore(root: root)
        let searchReady = expectation(description: "persisted latest segment adopted")
        store!.onSearchIndexLoaded = { searchReady.fulfill() }
        wait(for: [searchReady], timeout: 5)
        XCTAssertEqual(store!.search("final epoch", kind: nil, pinnedOnly: false).map(\.id), [row.id])
        XCTAssertTrue(store!.search("token1799", kind: nil, pinnedOnly: false).isEmpty)
    }

    func testCancellationStopsSupersededQuery() throws {
        let rows = (0..<1_000).map { record("document \($0) " + String(repeating: "body ", count: 100)) }
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview)!)
        })
        let snapshot = ClipSearchSnapshot(
            records: rows, index: entries,
            invertedIndex: ClipSearchIndex.build(records: rows, entries: entries)
        )
        let token = ClipSearchCancellationToken()
        token.cancel()
        let outcome = ClipSearch.run(
            ClipSearchRequest(query: try ClipQueryParser.parse("body"), cancellation: token),
            in: snapshot
        )
        XCTAssertTrue(outcome.cancelled)
        XCTAssertTrue(outcome.records.isEmpty)
    }

    func testFiveThousandLargeEntriesP95SearchUnderThirtyMillisecondsAndBudgeted() throws {
        let runtimeBaseline = Self.physicalFootprint()
        var rows: [ClipRecord] = []
        var entries: [UUID: ClipSearchEntry] = [:]
        rows.reserveCapacity(5_000)
        entries.reserveCapacity(5_000)
        var targetToken = ""
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        let valueSpace = 60_466_176 // 36^5; enough for all 13.5M unique tokens.
        for document in 0..<5_000 {
            var bodyBytes: [UInt8] = []
            bodyBytes.reserveCapacity(32_399)
            for token in 0..<2_700 {
                let ordinal = UInt64(document * 2_700 + token)
                let start = bodyBytes.count
                bodyBytes.append(0x75)
                // The trailing five digits are a bijection over 36^5, guaranteeing
                // uniqueness; the leading five independently mix the value so each
                // document has genuinely high-cardinality trigrams instead of shared
                // runs of zeroes from a formatted counter.
                let unique = (ordinal &* 7_919 &+ 104_729) % UInt64(valueSpace)
                let mixed = (unique &* 1_299_709 &+ 2_654_435_761) % UInt64(valueSpace)
                for initial in [mixed, unique] {
                    var value = initial
                    let digitStart = bodyBytes.count
                    bodyBytes.append(contentsOf: repeatElement(0x30, count: 5))
                    for offset in stride(from: 4, through: 0, by: -1) {
                        bodyBytes[digitStart + offset] = alphabet[Int(value % 36)]
                        value /= 36
                    }
                }
                if document == 4_999, token == 2_699 {
                    targetToken = String(decoding: bodyBytes[start...], as: UTF8.self)
                }
                if token != 2_699 { bodyBytes.append(0x20) }
            }
            let body = String(decoding: bodyBytes, as: UTF8.self)
            XCTAssertGreaterThanOrEqual(body.utf8.count, 32_000)
            XCTAssertLessThanOrEqual(body.utf8.count, 32_768)
            let row = record(String(body.prefix(400)))
            rows.append(row)
            entries[row.id] = ClipSearch.makeEntry(text: body)!
        }
        let fixtureFootprint = Self.physicalFootprint()
        let sampleLock = NSLock()
        var keepSampling = true
        var buildPeakFootprint = fixtureFootprint
        let sampleDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while sampleLock.withLock({ keepSampling }) {
                let footprint = Self.physicalFootprint()
                sampleLock.withLock {
                    buildPeakFootprint = max(buildPeakFootprint, footprint)
                }
                usleep(5_000)
            }
            sampleDone.signal()
        }
        let builtAt = ProcessInfo.processInfo.systemUptime
        let index = ClipSearchIndex.build(records: rows, entries: entries)
        let buildElapsed = ProcessInfo.processInfo.systemUptime - builtAt
        sampleLock.withLock { keepSampling = false }
        XCTAssertEqual(sampleDone.wait(timeout: .now() + 2), .success)
        _ = malloc_zone_pressure_relief(malloc_default_zone(), 0)
        let indexedFootprint = Self.physicalFootprint()
        let measuredBuildPeak = sampleLock.withLock { buildPeakFootprint }
        let totalIndexedFootprint = indexedFootprint >= runtimeBaseline
            ? indexedFootprint - runtimeBaseline : 0
        let totalBuildPeak = measuredBuildPeak >= runtimeBaseline
            ? measuredBuildPeak - runtimeBaseline : 0
        XCTAssertLessThanOrEqual(index.estimatedResidentBytes, ClipSearchIndex.maximumResidentBytes)
        XCTAssertLessThanOrEqual(
            index.peakBuildResidentBytes, ClipSearchIndex.maximumResidentBytes
        )
        XCTAssertLessThanOrEqual(
            totalIndexedFootprint, UInt64(ClipSearchIndex.maximumResidentBytes),
            "total live records + search bodies + filters + postings must fit the hard cap"
        )
        XCTAssertLessThanOrEqual(
            totalBuildPeak, UInt64(ClipSearchIndex.maximumResidentBytes),
            "real sampled construction peak must include bodies and stay under the hard cap"
        )
        XCTAssertEqual(index.documentIDs.count, 5_000)
        XCTAssertEqual(index.overflowDocumentCount, 5_000)
        XCTAssertLessThan(buildElapsed, 12, "index construction has a hard regression ceiling")

        let snapshot = ClipSearchSnapshot(records: rows, index: entries, invertedIndex: index)
        let request = ClipSearchRequest(query: try ClipQueryParser.parse(targetToken))
        let candidateStarted = ProcessInfo.processInfo.systemUptime
        let candidateProbe = index.candidates(for: targetToken)
        let candidateElapsed = ProcessInfo.processInfo.systemUptime - candidateStarted
        print(
            "SEARCH_HIGH_CARDINALITY_CANDIDATES count=\(candidateProbe.ids.count) "
                + "elapsed=\(candidateElapsed)"
        )
        XCTAssertLessThanOrEqual(candidateProbe.ids.count, 2)
        let warm = ClipSearch.run(request, in: snapshot)
        XCTAssertEqual(warm.records.map(\.id), [rows[4_999].id])
        guard warm.records.map(\.id) == [rows[4_999].id] else { return }
        var samples: [Double] = []
        for _ in 0..<25 {
            let began = ProcessInfo.processInfo.systemUptime
            let result = ClipSearch.run(request, in: snapshot)
            samples.append(ProcessInfo.processInfo.systemUptime - began)
            XCTAssertEqual(result.records.map(\.id), [rows[4_999].id])
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int(ceil(Double(samples.count) * 0.95)) - 1)]
        print(
            "SEARCH_HIGH_CARDINALITY build=\(buildElapsed) p50=\(p50) p95=\(p95) "
                + "estimatedIndexBytes=\(index.estimatedResidentBytes) "
                + "peakBuildBytes=\(index.peakBuildResidentBytes)"
        )
        XCTAssertLessThan(p95, 0.030, "P95=\(p95)s")

        // Cold adoption uses all 16 real encode -> AES-GCM seal -> atomic write -> read
        // -> authenticated open -> decode -> adopt transitions. Empty replacement bytes
        // are forbidden for every occupied slot.
        let persistenceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hyper-search-high-cardinality-\(UUID().uuidString)", isDirectory: true
        )
        roots.append(persistenceRoot)
        try FileManager.default.createDirectory(
            at: persistenceRoot, withIntermediateDirectories: true
        )
        let vault = ClipboardVault(
            provider: EphemeralClipboardVaultKeyProvider(
                scope: "search-high-cardinality-\(UUID().uuidString)"
            )
        )
        XCTAssertEqual(
            vault.prepare(hasEncryptedLibrary: false, hasLegacyPlaintext: false), .ready
        )
        var cold = ClipSearchIndex.empty
        var occupiedSlots = Set<Int>()
        var persistedBytes = 0
        for slot in 0..<ClipSearchIndex.segmentCount {
            let bytes = try index.encodedSegment(slot: slot)
            let context = String(format: "search-index/segment-%02d.json", slot)
            let sealed = try vault.seal(bytes, context: context)
            let url = persistenceRoot.appendingPathComponent(
                String(format: "segment-%02d.json", slot)
            )
            try sealed.write(to: url, options: .atomic)
            let stored = try Data(contentsOf: url, options: .mappedIfSafe)
            XCTAssertTrue(ClipboardVault.isSealed(stored))
            let opened = try vault.open(stored, context: context)
            let segment = try ClipSearchIndex.decodeSegment(opened, expectedSlot: slot)
            if segment.documentCount > 0 { occupiedSlots.insert(slot) }
            let expectedCount = index.segment(slot: slot)?.documentCount ?? 0
            XCTAssertEqual(segment.documentCount, expectedCount)
            if expectedCount > 0 {
                XCTAssertFalse(opened.isEmpty, "occupied slot must never persist as empty")
            }
            persistedBytes += stored.count
            try cold.replaceSegment(segment)
        }
        XCTAssertEqual(occupiedSlots.count, ClipSearchIndex.segmentCount)
        XCTAssertEqual(cold.documentIDs.count, rows.count)
        let coldSnapshot = ClipSearchSnapshot(
            records: rows, index: entries, invertedIndex: cold
        )
        var coldSamples: [Double] = []
        for _ in 0..<25 {
            let began = ProcessInfo.processInfo.systemUptime
            let result = ClipSearch.run(request, in: coldSnapshot)
            coldSamples.append(ProcessInfo.processInfo.systemUptime - began)
            XCTAssertEqual(result.records.map(\.id), [rows[4_999].id])
        }
        coldSamples.sort()
        let coldP95 = coldSamples[
            min(coldSamples.count - 1, Int(ceil(Double(coldSamples.count) * 0.95)) - 1)
        ]
        print(
            "SEARCH_HIGH_CARDINALITY_COLD p95=\(coldP95) persistedBytes=\(persistedBytes)"
        )
        let footprintDelta = indexedFootprint >= fixtureFootprint
            ? indexedFootprint - fixtureFootprint : 0
        print(
            "SEARCH_HIGH_CARDINALITY_MEMORY runtimeBaseline=\(runtimeBaseline) "
                + "fixture=\(fixtureFootprint) indexed=\(indexedFootprint) "
                + "structureDelta=\(footprintDelta) "
                + "totalIndexed=\(totalIndexedFootprint) "
                + "sampledBuildPeak=\(measuredBuildPeak) totalBuildPeak=\(totalBuildPeak) "
                + "hardCap=\(ClipSearchIndex.maximumResidentBytes)"
        )
        XCTAssertLessThan(coldP95, 0.030, "cold P95=\(coldP95)s")
    }

    /// Deterministic random walks of upserts and removals, verified against a fresh
    /// full rebuild. This is the guard on the tombstoned `GramTable`: reusing a freed
    /// slot, skipping a stale one and repacking at the compaction threshold must all be
    /// invisible to `candidates`, `documentIDs` and the search results themselves.
    ///
    /// Several seeds rather than one, because a single removal order exercises only one
    /// arrangement of tombstones and free slots.
    func testRandomUpsertRemoveSequenceMatchesAFullRebuild() throws {
        let seeds: [UInt64] = [
            0x5DEE_CE66_D9AB_1234, 1, 7, 99, 0xFFFF_FFFF, 0xA5A5_A5A5_A5A5_A5A5,
        ]
        for seed in seeds {
            try runRandomIndexWalk(seed: seed)
        }
    }

    private func runRandomIndexWalk(seed initialSeed: UInt64) throws {
        var seed = initialSeed
        func advance() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed
        }
        func next(_ bound: Int) -> Int { Int((advance() >> 33) % UInt64(bound)) }
        // Record ids come from the same generator as the walk itself. `UUID()` made slot
        // assignment — and therefore the whole arrangement of tombstones and free slots —
        // differ on every run, so a failure could not be reproduced from the seed alone.
        func nextUUID() -> UUID {
            let high = advance()
            let low = advance()
            var bytes = [UInt8]()
            bytes.reserveCapacity(16)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((high >> UInt64(shift)) & 0xFF))
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((low >> UInt64(shift)) & 0xFF))
            }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13],
                bytes[14], bytes[15]
            ))
        }

        let population = (0..<400).map { ordinal -> ClipRecord in
            record(
                "alpha\(ordinal) shared\(ordinal % 7) 剪贴板\(ordinal % 5) payload",
                app: ordinal.isMultiple(of: 3) ? "Editor" : "Terminal",
                id: nextUUID()
            )
        }
        XCTAssertEqual(
            Set(population.map(\.id)).count, population.count,
            "seed \(initialSeed) produced colliding ids"
        )
        let entries = Dictionary(uniqueKeysWithValues: population.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview + " body text " + $0.preview)!)
        })

        var index = ClipSearchIndex.empty
        var live: Set<UUID> = []
        var removals = 0
        var batchRemovals = 0

        for step in 0..<4_000 {
            let roll = next(100)
            if roll < 55 {
                let record = population[next(population.count)]
                index.upsert(record: record, entry: entries[record.id]!)
                live.insert(record.id)
            } else if roll < 92 {
                guard !live.isEmpty else { continue }
                // Sorted, not `Array(live)`: Set iteration order is seeded per process,
                // and a randomly ordered walk makes a divergence unreproducible.
                let victim = live.sorted { $0.uuidString < $1.uuidString }[next(live.count)]
                index.remove(victim)
                live.remove(victim)
                removals += 1
            } else {
                guard live.count >= 4 else { continue }
                let ordered = live.sorted { $0.uuidString < $1.uuidString }
                var batch = Set<UUID>()
                for _ in 0..<min(9, ordered.count) { batch.insert(ordered[next(ordered.count)]) }
                index.remove(batch)
                live.subtract(batch)
                batchRemovals += 1
            }

            // Intermediate spot-checks keep a divergence attributable to a step rather
            // than only visible at the end of four thousand of them.
            if step.isMultiple(of: 997) {
                XCTAssertEqual(index.documentIDs, live, "seed \(initialSeed) step \(step)")
            }
        }

        XCTAssertGreaterThan(removals, 100)
        XCTAssertGreaterThan(batchRemovals, 10)
        XCTAssertEqual(index.documentIDs, live, "seed \(initialSeed)")

        // A walk can drain to empty by chance, and an empty index would compare equal to
        // a rebuild trivially. Refill from a fixed slice so the comparison below always
        // has documents — and tombstoned slots being reused — to disagree about.
        for record in population.prefix(40) {
            index.upsert(record: record, entry: entries[record.id]!)
            live.insert(record.id)
        }
        XCTAssertEqual(index.documentIDs, live, "seed \(initialSeed) after refill")
        XCTAssertGreaterThanOrEqual(live.count, 40)

        let survivors = population.filter { live.contains($0.id) }
        let rebuilt = ClipSearchIndex.build(records: survivors, entries: entries)
        XCTAssertEqual(index.documentIDs, rebuilt.documentIDs, "seed \(initialSeed)")

        let probes = [
            "alpha7", "alpha399", "shared3", "payload", "剪贴板2", "jiantieban",
            "alpha0 shared0", "missingtoken", "!!!", "alph",
        ]
        for probe in probes {
            XCTAssertEqual(
                index.candidates(for: probe).ids,
                rebuilt.candidates(for: probe).ids,
                "candidate sets diverged for \(probe) at seed \(initialSeed)"
            )
        }

        // The verifier on top of those candidates must land on the same rows too.
        let liveEntries = entries.filter { live.contains($0.key) }
        for probe in ["alpha7", "shared3", "payload", "剪贴板2"] {
            let query = try ClipQueryParser.parse(probe)
            let incremental = ClipSearch.run(
                ClipSearchRequest(query: query),
                in: ClipSearchSnapshot(
                    records: survivors, index: liveEntries, invertedIndex: index
                )
            )
            let full = ClipSearch.run(
                ClipSearchRequest(query: query),
                in: ClipSearchSnapshot(
                    records: survivors, index: liveEntries, invertedIndex: rebuilt
                )
            )
            XCTAssertEqual(
                incremental.records.map(\.id), full.records.map(\.id),
                "search results diverged for \(probe) at seed \(initialSeed)"
            )
        }
    }

    func testRemovingEverySegmentDocumentReleasesItsFilterTable() throws {
        let rows = (0..<64).map { record("release\($0) body") }
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview)!)
        })
        var index = ClipSearchIndex.empty
        for row in rows { index.upsert(record: row, entry: entries[row.id]!) }
        XCTAssertEqual(index.documentIDs.count, rows.count)

        index.remove(Set(rows.map(\.id)))
        XCTAssertTrue(index.documentIDs.isEmpty)
        XCTAssertTrue(index.segments.isEmpty)
        XCTAssertTrue(index.candidates(for: "release3").ids.isEmpty)

        // Reinserting after a full teardown must recover a usable table rather than
        // resurrecting a tombstoned slot's stale bits.
        index.upsert(record: rows[0], entry: entries[rows[0].id]!)
        XCTAssertEqual(index.candidates(for: "release0").ids, [rows[0].id])
        XCTAssertTrue(index.candidates(for: "release1").ids.isEmpty)
    }

    /// Ids that all land in one segment, so a single packed filter table sees every
    /// insertion and deletion the test performs.
    private func idsSharingOneSlot(_ count: Int) -> [UUID] {
        var found: [UUID] = []
        var target: Int?
        while found.count < count {
            let candidate = UUID()
            let slot = ClipSearchIndex.slot(for: candidate)
            if let target {
                if slot == target { found.append(candidate) }
            } else {
                target = slot
                found.append(candidate)
            }
        }
        return found
    }

    /// Every claim the index makes about its own footprint, checked against the bytes it
    /// is really holding. All ids share one slot, so the live filter bytes are exactly
    /// `documentIDs.count * width` and anything above that is tombstone residue.
    private func assertFootprintIsHonest(
        _ index: ClipSearchIndex, _ context: String, line: UInt = #line
    ) {
        let width = ClipSearchIndex.gramFilterByteCount
        let tombstoneBytes = index.residentFilterByteCount - index.documentIDs.count * width
        XCTAssertGreaterThanOrEqual(tombstoneBytes, 0, context, line: line)
        XCTAssertGreaterThanOrEqual(
            index.gramTableOverheadBytes,
            tombstoneBytes + index.documentIDs.count * ClipSearchIndex.documentIDBytes,
            "\(context): overhead must cover tombstone residue and the cached id set",
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            index.estimatedResidentBytes,
            index.residentFilterByteCount
                + index.documentIDs.count * ClipSearchIndex.documentIDBytes,
            "\(context): the estimate must never claim less than what is held",
            line: line
        )
    }

    func testTombstonedFilterSlotsStayChargedToTheResidentBudget() throws {
        let ids = idsSharingOneSlot(40)
        let rows = ids.enumerated().map { record("tombstone\($0.offset) body text", id: $0.element) }
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, ClipSearch.makeEntry(text: $0.preview)!)
        })
        var index = ClipSearchIndex.empty
        for row in rows { index.upsert(record: row, entry: entries[row.id]!) }

        let width = ClipSearchIndex.gramFilterByteCount
        XCTAssertEqual(index.residentFilterByteCount, rows.count * width)
        let packedOverhead = index.gramTableOverheadBytes
        let fullEstimate = index.estimatedResidentBytes
        assertFootprintIsHonest(index, "fully packed")

        // Every other assertion in this file is a bound, and a bound cannot notice a term
        // that quietly went missing from the counter. So: with no tombstones, the overhead
        // is exactly the per-document charge — slot array, offset map and cached id — for
        // each of the forty documents.
        XCTAssertEqual(
            packedOverhead, rows.count * ClipSearchIndex.perDocumentOverheadBytes,
            "a packed table's overhead is the per-document charge and nothing else"
        )

        // Two deletions out of forty is under the one-tenth compaction threshold, so the
        // bytes stay packed — and must stay charged.
        index.remove(rows[0].id)
        index.remove(rows[1].id)
        XCTAssertEqual(
            index.residentFilterByteCount, rows.count * width,
            "below the threshold the table is not repacked"
        )
        XCTAssertEqual(index.documentIDs.count, rows.count - 2)
        assertFootprintIsHonest(index, "two tombstones")

        // Priced exactly. A tombstone keeps its filter slot and its `ids` entry resident,
        // hands back one offset-map entry and one cached id, and takes on one free-list
        // entry — so the counter must move by precisely that, twice over. Drop any single
        // term from `refreshGramOverhead` and this number changes.
        let tombstoneCost = width - ClipSearchIndex.gramOffsetBytes
            - ClipSearchIndex.documentIDBytes + ClipSearchIndex.freeSlotBytes
        XCTAssertEqual(
            index.gramTableOverheadBytes, packedOverhead + 2 * tombstoneCost,
            "a tombstone must charge its resident filter and discount only what it freed"
        )
        XCTAssertGreaterThan(
            index.gramTableOverheadBytes, packedOverhead + width,
            "two still-resident filters outweigh the dictionary entries that were freed"
        )
        XCTAssertGreaterThan(
            index.estimatedResidentBytes, fullEstimate - 2 * width,
            "deleting two documents must not discount bytes that are still held"
        )

        // Reinsert into the freed slots: the table does not grow and the tombstone
        // residue is charged back out, exactly.
        index.upsert(record: rows[0], entry: entries[rows[0].id]!)
        index.upsert(record: rows[1], entry: entries[rows[1].id]!)
        XCTAssertEqual(index.residentFilterByteCount, rows.count * width)
        XCTAssertEqual(index.documentIDs.count, rows.count)
        XCTAssertEqual(index.gramTableOverheadBytes, packedOverhead)
        XCTAssertEqual(index.estimatedResidentBytes, fullEstimate)
        assertFootprintIsHonest(index, "refilled")

        // Past the threshold the table is repacked, and the accounting follows it down.
        for row in rows.prefix(20) { index.remove(row.id) }
        XCTAssertEqual(index.documentIDs.count, rows.count - 20)
        XCTAssertLessThan(
            index.residentFilterByteCount, rows.count * width,
            "a tenth of the table tombstoned must trigger a repack"
        )
        XCTAssertLessThan(
            index.residentFilterByteCount - index.documentIDs.count * width,
            rows.count * width / 10,
            "repacking must keep the residue under the threshold it fires at"
        )
        XCTAssertLessThan(index.estimatedResidentBytes, fullEstimate)
        assertFootprintIsHonest(index, "after twenty deletions")

        // The batch path releases slots on the same terms.
        index.remove(Set(rows.suffix(20).map(\.id)))
        XCTAssertEqual(index.residentFilterByteCount, 0)
        XCTAssertEqual(index.gramTableOverheadBytes, 0)
        XCTAssertTrue(index.documentIDs.isEmpty)
        XCTAssertTrue(index.segments.isEmpty)
    }

    func testADesynchronisedFilterTableIsRefusedInsteadOfPersistedAsAnEmptySegment() throws {
        let ids = idsSharingOneSlot(2)
        let slot = ClipSearchIndex.slot(for: ids[0])
        let resident = record("resident body", id: ids[0])
        let entry = try XCTUnwrap(ClipSearch.makeEntry(text: resident.preview))
        var index = ClipSearchIndex.empty
        index.upsert(record: resident, entry: entry)
        XCTAssertNotNil(index.segment(slot: slot))
        let healthy = try index.encodedSegment(slot: slot)
        let healthyDocumentCount = try ClipSearchIndex
            .decodeSegment(healthy, expectedSlot: slot).documents.count
        XCTAssertEqual(healthyDocumentCount, 1)

        // `replaceSegment` installs documents that carry no filter bytes, so the repack
        // it runs afterwards declines — leaving the previous slot's packed table pointing
        // at a document that is no longer there. That is the desynchronisation.
        let replacement = ClipSearchIndex.Segment(
            slot: slot,
            documents: [ids[1]: ClipSearchIndex.Document(
                recordDigest: "replacement",
                entryDigest: String(repeating: "a", count: 64),
                tokens: [], overflowed: true, bodyResidentBytes: 64, gramFilter: Data()
            )],
            postings: [:]
        )
        try index.replaceSegment(replacement)

        XCTAssertNil(
            index.segment(slot: slot),
            "a slot whose filter table and documents disagree has no honest answer"
        )
        XCTAssertThrowsError(try index.encodedSegment(slot: slot)) { error in
            XCTAssertEqual(error as? ClipSearchIndex.Failure, .malformed)
        }

        // An untouched slot is still perfectly encodable, and a genuinely empty slot
        // still persists as an empty segment rather than throwing.
        let emptySlot = (0..<ClipSearchIndex.segmentCount).first { $0 != slot }
        let emptyBytes = try index.encodedSegment(slot: try XCTUnwrap(emptySlot))
        XCTAssertTrue(
            try ClipSearchIndex.decodeSegment(
                emptyBytes, expectedSlot: try XCTUnwrap(emptySlot)
            ).documents.isEmpty
        )
    }
}
