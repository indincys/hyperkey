import CoreGraphics

/// Virtual key codes and the modifier bookkeeping tables.
///
/// The name→keycode table follows the ANSI (US QWERTY) physical layout, which is
/// what virtual key codes describe. That means a binding of `"c"` fires on the key
/// *positioned* where `C` sits on a US keyboard — which is what muscle memory wants.
/// For anything not in the table, a config value may use the raw form `kc:8`.
enum Keys {
    static let f18: CGKeyCode = 79

    static let command: CGKeyCode = 55
    static let shift: CGKeyCode = 56
    static let capsLock: CGKeyCode = 57
    static let option: CGKeyCode = 58
    static let control: CGKeyCode = 59
    static let function: CGKeyCode = 63
    static let escape: CGKeyCode = 53

    /// Every key code that produces a `flagsChanged` event, and the flag it owns.
    static let modifierFlags: [CGKeyCode: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        63: .maskSecondaryFn,
    ]

    static let byName: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func code(for token: String) -> CGKeyCode? {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("kc:"), let n = UInt16(t.dropFirst(3)) { return CGKeyCode(n) }
        return byName[t]
    }

    /// Names that are accepted on input but are never what we write back out.
    private static let aliases: Set<String> = ["esc"]

    /// Canonical name per key code. Built explicitly because `byName` holds aliases and
    /// dictionary iteration order is not defined — picking the "first" match would make
    /// the spelling we save vary between runs.
    private static let canonicalNames: [CGKeyCode: String] = {
        var table: [CGKeyCode: String] = [:]
        for (name, code) in byName where !aliases.contains(name) {
            table[code] = name
        }
        return table
    }()

    /// The config spelling for a key code. Anything without a name round-trips as a
    /// raw code, so the recorder can accept keys this table has never heard of.
    static func name(for code: CGKeyCode) -> String {
        canonicalNames[code] ?? "kc:\(code)"
    }

    /// How a key is shown in the UI — the symbols people expect on a Mac.
    static let displayNames: [String: String] = [
        "space": "Space", "return": "↩", "tab": "⇥", "delete": "⌫", "escape": "⎋",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
    ]

    static func display(for code: CGKeyCode) -> String {
        let key = name(for: code)
        if let pretty = displayNames[key] { return pretty }
        return key.count == 1 ? key.uppercased() : key
    }

    static func display(forName name: String) -> String {
        if let pretty = displayNames[name] { return pretty }
        return name.count == 1 ? name.uppercased() : name
    }
}
