import CoreGraphics
import XCTest

@testable import Hyper

/// The config file is hand-edited, so every test here is really a question about what
/// happens to a file someone typed by hand: a missing key, a stale key, a key that does
/// not name anything.
final class ConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyper-config-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func targets(of config: Config) -> [String: String] {
        Dictionary(uniqueKeysWithValues: config.bindingNames.map { ($0.key, $0.target) })
    }

    // MARK: - Defaults

    func testMissingFileWritesAndParsesTheShippedDefault() throws {
        let config = try XCTUnwrap(ConfigStore.load())

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ConfigStore.url.path),
            "the default should be written out so the user has something to edit"
        )
        XCTAssertTrue(config.enabled)
        XCTAssertFalse(config.debug)
        XCTAssertEqual(config.tapActionRaw, "none")
        XCTAssertEqual(config.tapThresholdMs, 200)
        XCTAssertEqual(config.repeatPress, .hide)
        XCTAssertTrue(config.clipboardBindingsSeeded, "a fresh install must not be re-seeded")

        // The three built-in actions ship bound.
        XCTAssertEqual(targets(of: config)["space"], BuiltinAction.clipboardPanel.rawValue)
        XCTAssertEqual(targets(of: config)["q"], BuiltinAction.clipEnqueue.rawValue)
        XCTAssertEqual(targets(of: config)["v"], BuiltinAction.clipPasteNext.rawValue)
        XCTAssertEqual(config.bindings.count, config.bindingNames.count)
        XCTAssertEqual(config.clipboard.joinSeparator, "\n")
        // The shipped file spells the panel keys out, so hand-editing has something to
        // copy rather than a setting only the picker knows about.
        XCTAssertEqual(config.clipboard.panelSize, ClipPanelSize.standard.rawValue)
        XCTAssertEqual(config.clipboard.panelPositionMode, .center)
        XCTAssertEqual(config.clipboard.returnActionMode, .paste)

        // Bindings are stored in a stable display order regardless of JSON key order.
        XCTAssertEqual(config.bindingNames.map(\.key), config.bindingNames.map(\.key).sorted())
    }

    func testDefaultJSONIsItselfValidJSON() throws {
        let data = try XCTUnwrap(ConfigStore.defaultJSON.data(using: .utf8))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    // MARK: - Bindings

    func testUnknownBindingKeyIsSkippedWithoutLosingTheRest() throws {
        try write(#"{"bindings": {"c": "com.google.Chrome", "notakey": "com.apple.Safari"}}"#)
        let config = try XCTUnwrap(ConfigStore.load())

        XCTAssertEqual(config.bindingNames.count, 1)
        XCTAssertEqual(targets(of: config)["c"], "com.google.Chrome")
        XCTAssertNil(targets(of: config)["notakey"])
        XCTAssertEqual(config.bindings[8]?.description, "com.google.Chrome")
    }

    func testBindingTargetsClassifyIntoBundleIDsPathsAndActions() throws {
        try write(
            """
            {"bindings": {
              "c": "com.google.Chrome",
              "t": "/Applications/Ghostty.app",
              "space": "@clipboard"
            }}
            """
        )
        let config = try XCTUnwrap(ConfigStore.load())

        guard case .bundleID(let id) = config.bindings[8] else {
            return XCTFail("expected a bundle identifier for 'c'")
        }
        XCTAssertEqual(id, "com.google.Chrome")

        guard case .path(let path) = config.bindings[17] else {
            return XCTFail("expected a path for 't'")
        }
        XCTAssertEqual(path, "/Applications/Ghostty.app")

        guard case .action(let action) = config.bindings[49] else {
            return XCTFail("expected a built-in action for 'space'")
        }
        XCTAssertEqual(action, .clipboardPanel)
    }

    func testUnknownBuiltinActionIsNotTreatedAsABundleID() {
        guard case .action = LaunchTarget(rawValue: "@clipboard") else {
            return XCTFail("expected a built-in action")
        }
        // An "@" target that names nothing falls through to a bundle identifier rather
        // than crashing or silently vanishing.
        guard case .bundleID(let id) = LaunchTarget(rawValue: "@nonesuch") else {
            return XCTFail("expected a bundle identifier")
        }
        XCTAssertEqual(id, "@nonesuch")
    }

    // MARK: - repeatPress

    func testLegacyToggleHideIfFrontmostMapsOntoRepeatPress() throws {
        try write(#"{"toggleHideIfFrontmost": true}"#)
        XCTAssertEqual(try XCTUnwrap(ConfigStore.load()).repeatPress, .hide)

        try write(#"{"toggleHideIfFrontmost": false}"#)
        XCTAssertEqual(try XCTUnwrap(ConfigStore.load()).repeatPress, .none)
    }

    func testNewRepeatPressKeyWinsOverTheLegacyBoolean() throws {
        try write(#"{"repeatPress": "cycle", "toggleHideIfFrontmost": true}"#)
        XCTAssertEqual(try XCTUnwrap(ConfigStore.load()).repeatPress, .cycle)
    }

    func testUnrecognisedRepeatPressValueFallsBackToHide() throws {
        // An unparseable value leaves the stored default in place, and the accessor
        // itself also defends against a raw string it does not know.
        try write(#"{"repeatPress": "explode", "toggleHideIfFrontmost": false}"#)
        XCTAssertEqual(try XCTUnwrap(ConfigStore.load()).repeatPress, .none)

        var config = Config()
        config.repeatPressRaw = "explode"
        XCTAssertEqual(config.repeatPress, .hide)
    }

    // MARK: - Clipboard section

    func testClipboardFieldsFallBackIndividually() throws {
        try write(#"{"clipboard": {"maxItems": 42, "recordImages": false}}"#)
        let clipboard = try XCTUnwrap(ConfigStore.load()).clipboard

        XCTAssertEqual(clipboard.maxItems, 42)
        XCTAssertFalse(clipboard.recordImages)
        // Everything unmentioned keeps the built-in default.
        XCTAssertTrue(clipboard.enabled)
        XCTAssertEqual(clipboard.retentionDays, 30)
        XCTAssertEqual(clipboard.maxItemMB, 20)
        XCTAssertTrue(clipboard.skipConcealed)
        XCTAssertTrue(clipboard.skipTransient)
        XCTAssertFalse(clipboard.restoreAfterPaste)
        XCTAssertEqual(clipboard.ignoredApps, [])
        XCTAssertEqual(clipboard.applicationRules, [:])
    }

    func testMissingClipboardSectionYieldsTheDefaults() throws {
        try write(#"{"enabled": true}"#)
        XCTAssertEqual(try XCTUnwrap(ConfigStore.load()).clipboard, ClipboardSettings())
    }

    func testNonsensicalLimitsAreClamped() throws {
        try write(
            """
            {"tapActionHoldMs": 1,
             "clipboard": {"retentionDays": 0, "maxItems": 1, "maxItemMB": 0}}
            """
        )
        let config = try XCTUnwrap(ConfigStore.load())
        XCTAssertEqual(config.tapActionHoldMs, 20)
        XCTAssertEqual(config.clipboard.retentionDays, 1)
        XCTAssertEqual(config.clipboard.maxItems, 10)
        XCTAssertEqual(config.clipboard.maxItemMB, 1)
        XCTAssertEqual(config.clipboard.maxItemBytes, 1024 * 1024)

        try write(#"{"tapActionHoldMs": 100000}"#)
        XCTAssertEqual(try XCTUnwrap(ConfigStore.load()).tapActionHoldMs, 500)
    }

    func testIgnoredAppsAreTrimmedDeduplicatedAndStripped() throws {
        try write(
            """
            {"clipboard": {"ignoredApps":
              ["  com.agilebits.onepassword  ", "", "com.agilebits.onepassword", "   ", "com.apple.Safari"]
            }}
            """
        )
        let ignored = try XCTUnwrap(ConfigStore.load()).clipboard.ignoredApps
        XCTAssertEqual(ignored, ["com.agilebits.onepassword", "com.apple.Safari"])
    }

    func testLegacyIgnoredAppsMigrateIntoIgnoreRules() throws {
        try write(#"{"clipboard":{"ignoredApps":["com.example.secret"]}}"#)

        let clipboard = try XCTUnwrap(ConfigStore.load()).clipboard

        XCTAssertEqual(clipboard.applicationRules, ["com.example.secret": .ignore])
        XCTAssertEqual(clipboard.ignoredApps, ["com.example.secret"])
    }

    func testLegacyIgnoredAppsSetterPreservesRicherRules() {
        var clipboard = ClipboardSettings()
        clipboard.applicationRules = [
            "com.example.editor": .textOnly,
            "com.example.chat": .noImages,
        ]

        clipboard.ignoredApps = ["com.example.secret"]
        XCTAssertEqual(clipboard.applicationRules, [
            "com.example.editor": .textOnly,
            "com.example.chat": .noImages,
            "com.example.secret": .ignore,
        ])

        clipboard.ignoredApps = []
        XCTAssertEqual(clipboard.applicationRules, [
            "com.example.editor": .textOnly,
            "com.example.chat": .noImages,
        ])
    }

    func testAllApplicationRuleModesParseAndInvalidEntriesDoNotBreakConfig() throws {
        try write(
            """
            {"clipboard":{"applicationRules":{
              " com.example.ignore ":"ignore",
              "com.example.text":"textOnly",
              "com.example.noimages":"noImages",
              "com.example.invalid":"eraseEverything",
              "":"ignore"
            }}}
            """
        )

        let rules = try XCTUnwrap(ConfigStore.load()).clipboard.applicationRules

        XCTAssertEqual(rules, [
            "com.example.ignore": .ignore,
            "com.example.text": .textOnly,
            "com.example.noimages": .noImages,
        ])
    }

    // MARK: - Panel appearance and ↩

    func testPanelSettingsParse() throws {
        try write(
            """
            {"clipboard": {"panelSize": "large", "panelPosition": "mouse", "returnAction": "copy"}}
            """
        )
        let clipboard = try XCTUnwrap(ConfigStore.load()).clipboard

        XCTAssertEqual(clipboard.panelSize, ClipPanelSize.large.rawValue)
        XCTAssertEqual(clipboard.panelPositionMode, .mouse)
        XCTAssertEqual(clipboard.returnActionMode, .copy)
        XCTAssertEqual(clipboard.panelDimensions.width, 480)
        XCTAssertEqual(clipboard.panelDimensions.height, 680)
    }

    func testPanelSettingsDefaults() throws {
        try write(#"{"clipboard": {"maxItems": 42}}"#)
        let clipboard = try XCTUnwrap(ConfigStore.load()).clipboard

        XCTAssertEqual(clipboard.panelSize, ClipPanelSize.standard.rawValue)
        XCTAssertEqual(clipboard.panelPositionMode, .center)
        XCTAssertEqual(clipboard.returnActionMode, .paste)
        XCTAssertEqual(clipboard.panelDimensions.width, 400)
        XCTAssertEqual(clipboard.panelDimensions.height, 576)
    }

    /// A value nobody recognises has to read as the default, not as an empty panel or a
    /// window pinned off-screen.
    func testUnknownPanelSettingsFallBackToDefaults() throws {
        try write(
            """
            {"clipboard": {"panelSize": "enormous", "panelPosition": "orbit", "returnAction": "shred"}}
            """
        )
        let clipboard = try XCTUnwrap(ConfigStore.load()).clipboard

        XCTAssertEqual(clipboard.panelSize, ClipPanelSize.standard.rawValue)
        XCTAssertEqual(clipboard.panelPosition, ClipPanelPosition.center.rawValue)
        XCTAssertEqual(clipboard.returnAction, ClipReturnAction.paste.rawValue)
        XCTAssertEqual(clipboard.panelDimensions.height, 576)

        // And so does a raw value that never came from the file at all.
        var settings = ClipboardSettings()
        settings.panelSize = "enormous"
        XCTAssertEqual(settings.panelDimensions.width, 400)

        XCTAssertEqual(ClipPanelSize.compact.dimensions.width, 360)
        XCTAssertEqual(ClipPanelSize.compact.dimensions.height, 480)
    }

    // MARK: - Failure

    func testUnparseableFileReturnsNilSoBindingsSurvive() throws {
        try write("{ this is not json")
        XCTAssertNil(ConfigStore.load(), "a broken file must not read as an empty config")
    }

    // MARK: - Round trip

    func testSaveThenLoadPreservesEverything() throws {
        var config = Config()
        config.enabled = false
        config.debug = true
        config.tapActionRaw = "ctrl+opt+cmd"
        config.tapThresholdMs = 350
        config.tapActionHoldMs = 120
        config.repeatPressRaw = RepeatPress.cycle.rawValue
        config.clipboardBindingsSeeded = true
        config.clipboard.enabled = false
        config.clipboard.retentionDays = 7
        config.clipboard.maxItems = 250
        config.clipboard.maxItemMB = 5
        config.clipboard.recordImages = false
        config.clipboard.skipConcealed = false
        config.clipboard.skipTransient = false
        config.clipboard.applicationRules = [
            "com.apple.Safari": .ignore,
            "com.example.editor": .textOnly,
            "com.example.chat": .noImages,
        ]
        config.clipboard.restoreAfterPaste = true
        config.clipboard.joinSeparator = "\n\n"
        config.clipboard.panelSize = ClipPanelSize.compact.rawValue
        config.clipboard.panelPosition = ClipPanelPosition.bottom.rawValue
        config.clipboard.returnAction = ClipReturnAction.copy.rawValue
        config.setBindings([("c", "com.google.Chrome"), ("space", "@clipboard")])

        XCTAssertTrue(ConfigStore.save(config))
        let reloaded = try XCTUnwrap(ConfigStore.load())

        XCTAssertEqual(reloaded.enabled, config.enabled)
        XCTAssertEqual(reloaded.debug, config.debug)
        XCTAssertEqual(reloaded.tapActionRaw, config.tapActionRaw)
        XCTAssertEqual(reloaded.tapThresholdMs, config.tapThresholdMs)
        XCTAssertEqual(reloaded.tapActionHoldMs, config.tapActionHoldMs)
        XCTAssertEqual(reloaded.repeatPress, .cycle)
        XCTAssertTrue(reloaded.clipboardBindingsSeeded)
        XCTAssertEqual(reloaded.clipboard, config.clipboard)
        XCTAssertEqual(reloaded.clipboard.panelPositionMode, .bottom)
        XCTAssertEqual(reloaded.clipboard.returnActionMode, .copy)
        XCTAssertEqual(reloaded.clipboard.panelDimensions.width, 360)
        XCTAssertEqual(targets(of: reloaded), targets(of: config))

        guard case .modifiers(let flags) = reloaded.tapAction else {
            return XCTFail("expected a modifier-only tap action")
        }
        XCTAssertEqual(flags, [.maskControl, .maskAlternate, .maskCommand])
    }

    // MARK: - Derived state

    func testSetBindingsSortsAndSkipsUnknownKeys() {
        var config = Config()
        config.setBindings([("space", "@clipboard"), ("c", "com.google.Chrome"), ("nope", "x")])

        XCTAssertEqual(config.bindingNames.map(\.key), ["c", "nope", "space"])
        XCTAssertEqual(config.bindings.count, 2, "'nope' names no key code")
        XCTAssertNotNil(config.bindings[8])
        XCTAssertNotNil(config.bindings[49])
    }

    func testSeedingNeverStealsAKeyTheUserAlreadyBound() {
        var config = Config()
        config.setBindings([("space", "com.apple.Safari")])

        let skipped = config.seedClipboardBindings()

        XCTAssertEqual(skipped, [.clipboardPanel], "the occupied key is reported, not repurposed")
        XCTAssertEqual(targets(of: config)["space"], "com.apple.Safari")
        XCTAssertEqual(targets(of: config)["q"], BuiltinAction.clipEnqueue.rawValue)
        XCTAssertEqual(targets(of: config)["v"], BuiltinAction.clipPasteNext.rawValue)
        XCTAssertTrue(config.clipboardBindingsSeeded)

        // Seeding again adds nothing: the actions are already bound somewhere.
        let before = targets(of: config)
        XCTAssertEqual(config.seedClipboardBindings(), [.clipboardPanel])
        XCTAssertEqual(targets(of: config), before)
    }

    func testTapActionParsing() {
        guard case .none = TapAction(rawValue: "") else { return XCTFail("empty is none") }
        guard case .none = TapAction(rawValue: " NONE ") else { return XCTFail("none is none") }

        guard case .key(let code, let flags) = TapAction(rawValue: "cmd+space") else {
            return XCTFail("expected a key with modifiers")
        }
        XCTAssertEqual(code, 49)
        XCTAssertEqual(flags, .maskCommand)

        guard case .key(let raw, let noFlags) = TapAction(rawValue: "kc:53") else {
            return XCTFail("expected a raw key code")
        }
        XCTAssertEqual(raw, 53)
        XCTAssertEqual(noFlags, [])

        // Anything unparseable degrades to doing nothing rather than to a wrong key.
        guard case .none = TapAction(rawValue: "cmd+notakey") else {
            return XCTFail("an unknown key should disable the tap action")
        }
    }
}
