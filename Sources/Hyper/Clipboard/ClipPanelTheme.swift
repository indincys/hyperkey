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
    /// What the sheet is tinted with where it is real Liquid Glass (macOS 26 and later).
    ///
    /// A different number from `panelTint` because it is laid over a different thing: the
    /// system's glass already carries most of the sheet's lightness and all of its rim,
    /// so the tint only has to pull it far enough towards white — or towards black — for
    /// a column of text to stay readable over whatever is behind it.
    var glassTint: Color
    /// Laid over the glass of a window that is not the key window.
    ///
    /// The system draws glass in a window without the keyboard as *inactive* glass:
    /// flatter, greyer, and far less of the tint. The preview card never has the
    /// keyboard — it must not take it from the search field — so left alone it is
    /// permanently the grey half of the pair: mid-grey under white text on the dark face,
    /// and a visibly dirtier white than the list beside it on the light one. This film
    /// puts back the colour the inactive material gave up.
    var inactiveFilm: Color
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
    /// What the selected row stands on. The plates are lighter than the sheet now rather
    /// than darker, so a selection cannot be told from its neighbours by fill alone: it
    /// is the one plate lifted off the glass.
    var selectionShadow: Color
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

    /// How thick every hairline in the panel is drawn: the window's own border, the
    /// header's chips, the outlined pills.
    ///
    /// One point normally, which is the line the design asks for. Under "increase
    /// contrast" a one-point line at 10% opacity is not a border, it is a suggestion of
    /// one, and the setting exists precisely for the people to whom it is invisible.
    var borderWidth: CGFloat = 1

    /// Whether the panel gave up its blur. Only true under "reduce transparency", where
    /// the sheet is a solid colour and the material behind it is drawing nothing.
    var opaque = false

    static let darkTheme = ClipPanelTheme(
        dark: true,
        panelTint: Color(white: 0.10, opacity: 0.52),
        glassTint: Color(white: 0.06, opacity: 0.38),
        inactiveFilm: Color(white: 0.10, opacity: 0.60),
        panelBorder: .white.opacity(0.16),
        text: Color(red: 0.957, green: 0.957, blue: 0.969),
        text2: .white.opacity(0.72),
        text3: .white.opacity(0.42),
        divider: .white.opacity(0.08),
        chip: .white.opacity(0.10),
        chipBorder: .white.opacity(0.18),
        selectionFill: .white.opacity(0.17),
        selectionBorder: .white.opacity(0.36),
        // None. The dark face's plates are translucent, so a shadow under one shows
        // *through* it and darkens the very fill that was meant to stand out.
        selectionShadow: .clear,
        checkedFill: Color(red: 0.541, green: 0.706, blue: 1.0).opacity(0.14),
        pillOn: .white.opacity(0.20),
        pillOnText: .white,
        keyCap: .white.opacity(0.12),
        tile: .white.opacity(0.065),
        tileBorder: .white.opacity(0.13),
        accent: Color(red: 0.541, green: 0.706, blue: 1.0),
        code: Color(red: 0.784, green: 0.910, blue: 0.831)
    )

    /// The light face is a white card on an off-white sheet, not a grey card on a white
    /// one. The first light face darkened everything that needed an edge — plates at 5%
    /// black, outlines at 8% — and seven of those in a column is a grey panel. Here the
    /// sheet carries the little colour there is, a cool off-white, and everything raised
    /// off it is simply white with a hairline: the thing being read is always the
    /// brightest thing on screen.
    static let lightTheme = ClipPanelTheme(
        dark: false,
        panelTint: Color(red: 0.945, green: 0.951, blue: 0.965, opacity: 0.74),
        glassTint: Color(red: 0.945, green: 0.951, blue: 0.965, opacity: 0.60),
        inactiveFilm: Color(red: 0.955, green: 0.960, blue: 0.972, opacity: 0.74),
        panelBorder: .white.opacity(0.75),
        text: Color(white: 0.105),
        text2: Color(red: 0.365, green: 0.365, blue: 0.392),
        text3: Color(red: 0.557, green: 0.557, blue: 0.588),
        divider: .black.opacity(0.06),
        chip: .white.opacity(0.82),
        chipBorder: .black.opacity(0.075),
        selectionFill: .white,
        selectionBorder: .black.opacity(0.085),
        selectionShadow: .black.opacity(0.13),
        checkedFill: Color(red: 0.0, green: 0.478, blue: 1.0).opacity(0.09),
        pillOn: .white,
        pillOnText: Color(white: 0.105),
        keyCap: .black.opacity(0.06),
        tile: .white.opacity(0.74),
        tileBorder: .black.opacity(0.055),
        accent: Color(red: 0.0, green: 0.478, blue: 1.0),
        code: Color(red: 0.122, green: 0.435, blue: 0.271)
    )

    /// The face, adjusted for the two accessibility settings that are about seeing it.
    ///
    /// `reduceTransparency` is the stronger of the two and the simpler: the panel is a
    /// blurred sheet with a translucent tint over it, which is exactly what the setting
    /// asks not to be given. The tint goes opaque and the material becomes the plain
    /// window background, so what is behind the panel stops showing through it at all.
    ///
    /// `increaseContrast` lifts the one colour that is deliberately faint — `text3`,
    /// which is captions, band headers and the ⌘n caps — to a ratio that clears WCAG AA
    /// against the panel's own ground, and draws every hairline at two points instead of
    /// one. The rest of the palette is left alone: `text` and `text2` already clear it,
    /// and rewriting a whole design at this setting produces a panel nobody designed.
    static func resolved(
        dark: Bool, reduceTransparency: Bool = false, increaseContrast: Bool = false
    ) -> ClipPanelTheme {
        var theme = dark ? ClipPanelTheme.darkTheme : .lightTheme
        if reduceTransparency {
            theme.opaque = true
            // The tint *is* the panel's colour; at full opacity it is the whole of it.
            theme.panelTint = dark
                ? Color(white: 0.11)
                : Color(red: 0.945, green: 0.951, blue: 0.965)
            theme.panelBorder = dark ? .white.opacity(0.22) : .black.opacity(0.18)
        }
        if increaseContrast {
            theme.text3 = dark
                ? .white.opacity(0.62)
                : Color(red: 0.353, green: 0.353, blue: 0.369)
            theme.text2 = dark ? .white.opacity(0.86) : Color(white: 0.24)
            theme.borderWidth = 2
            theme.panelBorder = dark ? .white.opacity(0.32) : .black.opacity(0.28)
            theme.chipBorder = dark ? .white.opacity(0.34) : .black.opacity(0.28)
            theme.divider = dark ? .white.opacity(0.24) : .black.opacity(0.22)
            theme.selectionBorder = dark ? .white.opacity(0.55) : .black.opacity(0.45)
            theme.tileBorder = dark ? .white.opacity(0.38) : .black.opacity(0.28)
        }
        return theme
    }

    /// The edge every plate, chip and capsule in the panel is drawn with.
    ///
    /// Lit from above, which is the whole of what makes a flat rounded rectangle read as
    /// a raised piece of something rather than as a box with a border. On the dark face
    /// the edge is light, so it is the top that carries it and the bottom that all but
    /// loses it; on the light face the edge is a shade, so it is the other way up — the
    /// underside is where a white plate on a pale sheet casts anything at all. Under
    /// "increase contrast" the palette has swapped the edge for one that is meant to be
    /// *seen*, and a line that faded away along one side would be undoing exactly that
    /// — so there it is solid.
    func rim(_ colour: Color) -> LinearGradient {
        let faint = colour.opacity(borderWidth > 1 ? 1 : (dark ? 0.32 : 0.55))
        return LinearGradient(
            colors: dark ? [colour, faint] : [faint, colour],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The appearance the two windows are stamped with, so AppKit's own pieces — the
    /// search field's editor, its insertion point, the scrollers, any menu opened from
    /// the header — come out the same colour as everything drawn here.
    var nsAppearance: NSAppearance? {
        NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// The blur behind the tint. `.hudWindow` is the one material that stays this dark
    /// under `darkAqua` without going opaque; `.popover` is the light face's counterpart
    /// and is what a floating sheet over a bright desktop reads as.
    var material: NSVisualEffectView.Material {
        // Under "reduce transparency" the tint above is already opaque, so the material
        // only decides what the system draws where the tint does not reach — a plain
        // window background rather than a vibrant sheet that has nothing to be vibrant
        // against.
        if opaque { return .windowBackground }
        return dark ? .hudWindow : .popover
    }
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
