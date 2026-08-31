import AppKit
import SwiftUI

/// Which of the two faces the panel wears, and whether that was a decision.
///
/// `system` is the default and the only value that changes on its own: the panel reads
/// the effective appearance on the way up, so a Mac that switches to dark at sunset gets
/// a dark panel without anything having to observe it. The other two are the ☾/☀ button
/// in the header — a deliberate override, remembered in the config like every other
/// panel setting, because someone who wants the list dark over a light desktop wants it
/// dark tomorrow too.
enum ClipPanelAppearance: String, CaseIterable {
    case system
    case dark
    case light

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    /// What the button does: the toggle only ever produces an explicit value, because
    /// the point of pressing it is to stop the panel deciding for itself. Which of the
    /// two it lands on is the opposite of what is on screen *now*, so the first press
    /// always visibly changes something whichever state it started from.
    func toggled(currentlyDark: Bool) -> ClipPanelAppearance {
        currentlyDark ? .light : .dark
    }

    /// Nil where the panel is to follow the system, which is the only case the caller
    /// has to resolve for itself.
    var forcedDark: Bool? {
        switch self {
        case .system: return nil
        case .dark: return true
        case .light: return false
        }
    }
}

/// Every colour the panel draws with, in one value.
///
/// Deliberately not `NSColor` semantic colours. The panel is a floating glass sheet that
/// can be dark over a light desktop — an override the header offers on purpose — and the
/// semantic palette follows the *window's* appearance, which would then be the one thing
/// on screen disagreeing with the panel it is drawn on. These are the prototype's own
/// values, kept as literals so the two faces are legible side by side and neither can
/// drift when the other is edited.
struct ClipPanelTheme: Equatable {
    var dark: Bool

    /// The tint laid over the blurred backdrop. The material alone is not the panel's
    /// colour: the prototype's sheet is a specific near-black at 58% over whatever is
    /// behind it, and vibrancy on its own lands much lighter than that over a bright
    /// desktop.
    var panelTint: Color
    var panelBorder: Color

    /// Primary, secondary and tertiary text. `text3` is captions, group headers and the
    /// ⌘n caps — anything the eye is meant to skip until it wants it.
    var text: Color
    var text2: Color
    var text3: Color

    var divider: Color
    /// The small square buttons in the header.
    var chip: Color
    var chipBorder: Color

    /// The row under the pointer or the keyboard. One state, not two: hovering a row
    /// selects it, so there is nothing a separate hover colour could say.
    var selectionFill: Color
    var selectionBorder: Color
    /// Ticked but not selected — the multi-selection's own, fainter mark.
    var checkedFill: Color

    var pillOn: Color
    var pillOnText: Color

    /// The little rounded key legends.
    var keyCap: Color

    /// Neutral plates: thumbnail placeholders, the "Aa" gutter's backing, file plates
    /// with no colour of their own.
    var tile: Color
    var tileBorder: Color

    var accent: Color
    /// Monospaced content — commands, JSON, paths.
    var code: Color

    static let darkTheme = ClipPanelTheme(
        dark: true,
        panelTint: Color(white: 0.11, opacity: 0.58),
        panelBorder: .white.opacity(0.14),
        text: Color(red: 0.949, green: 0.949, blue: 0.961),
        text2: .white.opacity(0.70),
        text3: .white.opacity(0.38),
        divider: .white.opacity(0.08),
        chip: .white.opacity(0.08),
        chipBorder: .white.opacity(0.10),
        selectionFill: .white.opacity(0.10),
        selectionBorder: .white.opacity(0.22),
        checkedFill: .white.opacity(0.05),
        pillOn: .white.opacity(0.92),
        pillOnText: Color(white: 0.07),
        keyCap: .white.opacity(0.12),
        tile: .white.opacity(0.08),
        tileBorder: .white.opacity(0.16),
        accent: Color(red: 0.541, green: 0.706, blue: 1.0),
        code: Color(red: 0.784, green: 0.910, blue: 0.831)
    )

    static let lightTheme = ClipPanelTheme(
        dark: false,
        panelTint: Color(white: 0.98, opacity: 0.62),
        panelBorder: .white.opacity(0.65),
        text: Color(white: 0.114),
        text2: Color(red: 0.431, green: 0.431, blue: 0.451),
        text3: Color(red: 0.604, green: 0.604, blue: 0.627),
        divider: .black.opacity(0.07),
        chip: .white.opacity(0.60),
        chipBorder: .black.opacity(0.06),
        selectionFill: .black.opacity(0.06),
        selectionBorder: .black.opacity(0.14),
        checkedFill: .black.opacity(0.035),
        pillOn: Color(white: 0.114),
        pillOnText: .white,
        keyCap: .black.opacity(0.07),
        tile: .black.opacity(0.05),
        tileBorder: .black.opacity(0.08),
        accent: Color(red: 0.0, green: 0.478, blue: 1.0),
        code: Color(red: 0.122, green: 0.435, blue: 0.271)
    )

    static func resolved(dark: Bool) -> ClipPanelTheme { dark ? .darkTheme : .lightTheme }

    /// The appearance the two windows are stamped with, so AppKit's own pieces — the
    /// search field's editor, its insertion point, the scrollers, any menu opened from
    /// the header — come out the same colour as everything drawn here.
    var nsAppearance: NSAppearance? {
        NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// The blur behind the tint. `.hudWindow` is the one material that stays this dark
    /// under `darkAqua` without going opaque; `.popover` is the light face's counterpart
    /// and is what a floating sheet over a bright desktop reads as.
    var material: NSVisualEffectView.Material { dark ? .hudWindow : .popover }
}

private struct ClipPanelThemeKey: EnvironmentKey {
    static let defaultValue = ClipPanelTheme.darkTheme
}

extension EnvironmentValues {
    var panelTheme: ClipPanelTheme {
        get { self[ClipPanelThemeKey.self] }
        set { self[ClipPanelThemeKey.self] = newValue }
    }
}

/// Whether the system is currently in dark mode, read without a window to ask.
///
/// `NSApp.effectiveAppearance` is the honest answer for an agent that has no ordinary
/// windows: it follows the system setting and updates live. Read on each `show()` rather
/// than observed — the panel opens often and lives briefly, so opening is late enough.
enum ClipPanelSystemAppearance {
    static var isDark: Bool {
        let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua
    }
}
