import CoreGraphics
import XCTest

@testable import Hyper

final class ShortcutProfileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-profile-tests-\(UUID().uuidString)", isDirectory: true)
        ConfigStore.directoryOverride = directory
    }

    override func tearDownWithError() throws {
        ConfigStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: ConfigStore.url)
    }

    func testLegacyBindingsMigrateToDefaultAndRemainInDowngradeMirror() throws {
        try write(#"{"bindings":{"c":"com.google.Chrome","space":"@clipboard"}}"#)

        var config = try XCTUnwrap(ConfigStore.load())
        XCTAssertEqual(config.profiles.count, 1)
        XCTAssertEqual(config.activeProfile?.name, "Default")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: config.activeProfile!.allBindings.map { ($0.key, $0.target) }),
            ["c": "com.google.Chrome", "space": "@clipboard"]
        )

        let work = ShortcutProfile(name: "Work", bindings: [
            ShortcutBinding(key: "x", target: "com.apple.dt.Xcode")
        ])
        config.profiles.append(work)
        XCTAssertTrue(config.activateProfile(work.id))
        XCTAssertTrue(ConfigStore.save(config))

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: ConfigStore.url)) as? [String: Any]
        )
        XCTAssertEqual(document["activeProfileID"] as? String, work.id.uuidString)
        XCTAssertEqual(document["bindings"] as? [String: String], ["x": "com.apple.dt.Xcode"])

        let reloaded = try XCTUnwrap(ConfigStore.load())
        XCTAssertEqual(reloaded.profiles.first(where: { $0.name == "Default" })?.allBindings.count, 2)
        XCTAssertEqual(reloaded.bindings[Keys.code(for: "x")!]?.description, "com.apple.dt.Xcode")
    }

    func testProfileArchiveRoundTripIsByteIdentical() throws {
        var config = Config()
        let defaultID = try XCTUnwrap(config.activeProfile?.id)
        config.setBindings([
            (key: "c", target: "com.google.Chrome"),
            (key: "space", target: BuiltinAction.clipboardPanel.rawValue),
        ])
        let second = ShortcutProfile(name: "Communication", bindings: [
            ShortcutBinding(key: "w", target: "com.tencent.xinWeChat"),
            ShortcutBinding(key: "q", target: BuiltinAction.clipEnqueue.rawValue),
        ])
        config.profiles.append(second)
        XCTAssertTrue(config.activateProfile(second.id))

        let exported = try ConfigStore.exportProfiles(config)
        var destination = Config()
        destination.setBindings([(key: "z", target: "com.example.old")])
        destination = try ConfigStore.importProfiles(exported, into: destination)
        let reexported = try ConfigStore.exportProfiles(destination)

        XCTAssertEqual(exported, reexported)
        XCTAssertEqual(destination.activeProfileID, second.id)
        XCTAssertEqual(destination.profiles.first(where: { $0.id == defaultID })?.name, "Default")
        XCTAssertEqual(destination.bindings[Keys.code(for: "w")!]?.description, "com.tencent.xinWeChat")
    }

    func testInvalidImportDoesNotMutateDestination() throws {
        var original = Config()
        original.setBindings([(key: "c", target: "com.google.Chrome")])
        let before = original
        let invalid = Data(#"{"schemaVersion":1,"activeProfileID":"00000000-0000-0000-0000-000000000099","profiles":[]}"#.utf8)

        XCTAssertThrowsError(try ConfigStore.importProfiles(invalid, into: original))
        XCTAssertEqual(original, before)
    }

    func testInvalidCandidateIsRejectedBeforeExistingFileIsTouched() throws {
        var original = Config()
        original.setBindings([(key: "c", target: "com.google.Chrome")])
        XCTAssertTrue(ConfigStore.save(original))
        let before = try Data(contentsOf: ConfigStore.url)

        var invalid = original
        invalid.profiles = []
        invalid.activeProfileID = nil
        XCTAssertFalse(ConfigStore.save(invalid))

        XCTAssertEqual(try Data(contentsOf: ConfigStore.url), before)
        XCTAssertEqual(try XCTUnwrap(ConfigStore.load()).bindingNames.first?.target, "com.google.Chrome")
    }

    func testTemplatesAreCompleteAndNeverOverwriteOccupiedKeys() throws {
        XCTAssertEqual(Set(ShortcutProfileTemplate.builtIns.map(\.name)), ["Work", "Communication", "Creator"])
        XCTAssertTrue(ShortcutProfileTemplate.builtIns.allSatisfy {
            !$0.profile.applicationBindings.isEmpty && !$0.profile.clipboardActionBindings.isEmpty
        })

        var config = Config()
        config.setBindings([
            (key: "c", target: "com.example.keep"),
            (key: "space", target: "com.example.keep-space"),
        ])
        let before = Dictionary(uniqueKeysWithValues: config.bindingNames.map { ($0.key, $0.target) })

        let result = config.importTemplate(ShortcutProfileTemplate.builtIns[0])
        let after = Dictionary(uniqueKeysWithValues: config.bindingNames.map { ($0.key, $0.target) })

        XCTAssertEqual(after["c"], before["c"])
        XCTAssertEqual(after["space"], before["space"])
        XCTAssertGreaterThan(result.skippedOccupiedKeys.count, 0)
        XCTAssertGreaterThan(result.importedCount, 0)
    }

    func testConflictEngineExplainsEveryRequiredClassInStableOrder() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let d = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let e = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let profile = ShortcutProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "Broken",
            applicationBindings: [
                ShortcutBinding(id: a, key: "c", target: "com.example.present"),
                ShortcutBinding(id: b, key: "C", target: "com.example.missing"),
                ShortcutBinding(id: c, key: "f19", target: "com.example.present"),
            ],
            clipboardActionBindings: [
                ShortcutBinding(id: d, key: "q", target: "@clip-enqueue"),
                ShortcutBinding(id: e, key: "v", target: "@not-an-action"),
                ShortcutBinding(key: "w", target: "@clip-enqueue"),
            ]
        )

        let first = ShortcutConflictEngine.evaluate(profile: profile) { $0 == "com.example.present" }
        let second = ShortcutConflictEngine.evaluate(profile: profile) { $0 == "com.example.present" }

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.kind), [
            .duplicateKey,
            .systemReservedKey,
            .duplicateBuiltinAction,
            .unknownBuiltinAction,
            .missingApplication,
        ])
        XCTAssertTrue(first.allSatisfy { !$0.explanation.isEmpty && !$0.bindingIDs.isEmpty })
    }

    func testProfileSwitchReplacesCompleteLookupAndCannotDuplicateAKey() throws {
        var config = Config()
        config.setBindings([(key: "c", target: "com.example.first")])
        let second = ShortcutProfile(name: "Second", bindings: [
            ShortcutBinding(key: "c", target: "com.example.second"),
            ShortcutBinding(key: "v", target: "@clip-paste-next"),
        ])
        config.profiles.append(second)

        XCTAssertTrue(config.activateProfile(second.id))
        XCTAssertEqual(config.bindings.count, 2)
        XCTAssertEqual(config.bindings[Keys.code(for: "c")!]?.description, "com.example.second")
        XCTAssertNil(config.bindings[Keys.code(for: "x")!])

        let snapshot = config
        XCTAssertFalse(config.activateProfile(UUID()))
        XCTAssertEqual(config, snapshot)
    }

    func testProfileManagementKeepsAtLeastOneAndNamesUnique() throws {
        var config = Config()
        let original = try XCTUnwrap(config.activeProfileID)
        let copy = try config.createProfile(named: "Default copy", copying: original)
        XCTAssertEqual(config.profiles.count, 2)
        XCTAssertThrowsError(try config.renameProfile(copy, to: " default "))
        XCTAssertTrue(config.deleteProfile(original))
        XCTAssertEqual(config.activeProfileID, copy)
        XCTAssertFalse(config.deleteProfile(copy))
        XCTAssertEqual(config.profiles.count, 1)
    }
}
