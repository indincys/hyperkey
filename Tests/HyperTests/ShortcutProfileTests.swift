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

    // MARK: - Resource budgets

    func testArchiveRejectsOversizedDataBeforeDecode() {
        let oversized = Data(repeating: 0x20, count: ShortcutProfileBudget.maxFileBytes + 1)
        let config = Config()

        XCTAssertThrowsError(try ConfigStore.importProfiles(oversized, into: config)) { error in
            XCTAssertEqual(error as? ShortcutProfileError, .fileTooLarge)
        }
        XCTAssertEqual(config.profiles.count, 1)
    }

    func testArchiveBudgetRejectsTooManyProfilesBindingsAndLongStrings() throws {
        let profile = ShortcutProfile(name: "Bounded", bindings: [
            ShortcutBinding(key: "c", target: "com.example.app")
        ])
        var archive = ShortcutProfileArchive(activeProfileID: profile.id, profiles: [profile])

        archive.profiles = (0...ShortcutProfileBudget.maxProfiles).map {
            ShortcutProfile(name: "P\($0)")
        }
        archive.activeProfileID = archive.profiles[0].id
        XCTAssertThrowsError(try archive.validate()) { error in
            XCTAssertEqual(error as? ShortcutProfileError, .tooManyProfiles)
        }

        archive = ShortcutProfileArchive(activeProfileID: profile.id, profiles: [profile])
        archive.profiles[0].applicationBindings = (0...ShortcutProfileBudget.maxBindingsPerProfile).map {
            ShortcutBinding(key: "kc:\($0)", target: "com.example.\($0)")
        }
        XCTAssertThrowsError(try archive.validate()) { error in
            XCTAssertEqual(error as? ShortcutProfileError, .tooManyBindingsInProfile("Bounded"))
        }

        archive = ShortcutProfileArchive(activeProfileID: profile.id, profiles: [profile])
        archive.profiles[0].name = String(repeating: "界", count: ShortcutProfileBudget.maxProfileNameBytes)
        XCTAssertThrowsError(try archive.validate()) { error in
            XCTAssertEqual(error as? ShortcutProfileError, .stringTooLong("Profile name"))
        }

        archive = ShortcutProfileArchive(activeProfileID: profile.id, profiles: [profile])
        archive.profiles[0].applicationBindings[0].key = String(
            repeating: "a", count: ShortcutProfileBudget.maxKeyBytes + 1
        )
        XCTAssertThrowsError(try archive.validate()) { error in
            XCTAssertEqual(error as? ShortcutProfileError, .stringTooLong("Key"))
        }

        archive = ShortcutProfileArchive(activeProfileID: profile.id, profiles: [profile])
        archive.profiles[0].applicationBindings[0].target = String(
            repeating: "a", count: ShortcutProfileBudget.maxTargetBytes + 1
        )
        XCTAssertThrowsError(try archive.validate()) { error in
            XCTAssertEqual(error as? ShortcutProfileError, .stringTooLong("Target"))
        }

        let crowded = (0..<17).map { profileIndex in
            ShortcutProfile(
                name: "Crowded \(profileIndex)",
                bindings: (0..<ShortcutProfileBudget.maxBindingsPerProfile).map { bindingIndex in
                    ShortcutBinding(
                        key: "kc:\(bindingIndex)",
                        target: "com.example.\(profileIndex).\(bindingIndex)"
                    )
                }
            )
        }
        archive = ShortcutProfileArchive(activeProfileID: crowded[0].id, profiles: crowded)
        XCTAssertThrowsError(try archive.validate()) { error in
            XCTAssertEqual(error as? ShortcutProfileError, .tooManyBindings)
        }
    }

    func testStartupRejectsOversizedConfigFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oversized = Data(repeating: 0x20, count: ShortcutProfileBudget.maxFileBytes + 1)
        try oversized.write(to: ConfigStore.url)

        XCTAssertNil(ConfigStore.load())
    }

    func testStartupRejectsTooManyLegacyBindingsWithoutPartialMigration() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bindings = Dictionary(uniqueKeysWithValues:
            (0...ShortcutProfileBudget.maxBindingsPerProfile).map {
                ("kc:\($0)", "com.example.legacy.\($0)")
            }
        )
        let data = try JSONSerialization.data(withJSONObject: ["bindings": bindings])
        XCTAssertLessThan(data.count, ShortcutProfileBudget.maxFileBytes)
        try data.write(to: ConfigStore.url)

        XCTAssertNil(ConfigStore.load())
    }

    func testStartupRejectsOversizedLegacyTargetWithoutPartialMigration() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oversizedTarget = String(
            repeating: "a", count: ShortcutProfileBudget.maxTargetBytes + 1
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "bindings": ["kc:7": oversizedTarget]
        ])
        XCTAssertLessThan(data.count, ShortcutProfileBudget.maxFileBytes)
        try data.write(to: ConfigStore.url)

        XCTAssertNil(ConfigStore.load())
    }

    // MARK: - Downgrade and import recovery

    func testNewThenOldSaveAutomaticallyRecoversAllProfilesFromSidecar() throws {
        var config = Config()
        config.setBindings([(key: "c", target: "com.google.Chrome")])
        let work = ShortcutProfile(name: "Work", bindings: [
            ShortcutBinding(key: "x", target: "com.apple.dt.Xcode")
        ])
        config.profiles.append(work)
        XCTAssertTrue(config.activateProfile(work.id))
        XCTAssertTrue(ConfigStore.save(config))

        // A pre-profile release rewrites only the legacy surface and drops every new key.
        try write(#"{"bindings":{"x":"com.apple.dt.Xcode"}}"#)

        let recovered = try XCTUnwrap(ConfigStore.load())
        XCTAssertEqual(recovered.activeProfileID, work.id)
        XCTAssertEqual(Set(recovered.profiles.map(\.name)), ["Default", "Work"])
        XCTAssertEqual(recovered.bindings[Keys.code(for: "x")!]?.description, "com.apple.dt.Xcode")
        XCTAssertFalse(ConfigStore.hasDowngradeRecovery, "exact legacy saves recover automatically")
    }

    func testExplicitResetDoesNotResurrectSidecarProfiles() throws {
        var config = Config()
        let work = ShortcutProfile(name: "Work", bindings: [
            ShortcutBinding(key: "x", target: "com.apple.dt.Xcode")
        ])
        config.profiles.append(work)
        XCTAssertTrue(config.activateProfile(work.id))
        XCTAssertTrue(ConfigStore.save(config))

        // Reset writes the shipped defaults, whose legacy mirror does not match the
        // sidecar baseline. Recovery must remain explicit rather than surprising.
        try write(ConfigStore.defaultJSON)
        let reset = try XCTUnwrap(ConfigStore.load())
        XCTAssertEqual(reset.profiles.count, 1)
        XCTAssertEqual(reset.activeProfile?.name, "Default")
        XCTAssertTrue(ConfigStore.hasDowngradeRecovery, "ambiguous/reset files require explicit UI restore")
    }

    func testImportRecoveryPointRestoresPreviousProfiles() throws {
        var original = Config()
        original.setBindings([(key: "c", target: "com.google.Chrome")])
        let imported = ShortcutProfile(name: "Imported", bindings: [
            ShortcutBinding(key: "s", target: "com.apple.Safari")
        ])
        var candidate = original
        candidate.profiles = [imported]
        candidate.activeProfileID = imported.id
        candidate.rebuildRuntimeBindings()

        XCTAssertTrue(ConfigStore.saveImportRecovery(original))
        XCTAssertTrue(ConfigStore.hasImportRecovery)
        XCTAssertTrue(ConfigStore.save(candidate))
        let restored = try ConfigStore.loadImportRecovery(into: candidate)

        XCTAssertEqual(restored.profiles, original.profiles)
        XCTAssertEqual(restored.activeProfileID, original.activeProfileID)
        XCTAssertEqual(restored.bindings[Keys.code(for: "c")!]?.description, "com.google.Chrome")
        ConfigStore.clearImportRecovery()
        XCTAssertFalse(ConfigStore.hasImportRecovery)
    }

    func testImportPreviewSummarizesAddedRemovedAndChangedProfiles() throws {
        var current = Config()
        current.setBindings([(key: "c", target: "com.google.Chrome")])
        let removed = ShortcutProfile(name: "Removed")
        current.profiles.append(removed)

        var changedDefault = try XCTUnwrap(current.activeProfile)
        changedDefault.name = "Default renamed"
        let added = ShortcutProfile(name: "Added")
        var candidate = current
        candidate.profiles = [changedDefault, added]
        candidate.activeProfileID = added.id
        candidate.rebuildRuntimeBindings()

        let preview = try XCTUnwrap(ProfileImportPreview.make(current: current, candidate: candidate))
        XCTAssertEqual(preview.addedNames, ["Added"])
        XCTAssertEqual(preview.removedNames, ["Removed"])
        XCTAssertEqual(preview.changedNames, ["Default renamed"])
        XCTAssertEqual(preview.currentProfileCount, 2)
        XCTAssertEqual(preview.profiles.count, 2)
    }
}
