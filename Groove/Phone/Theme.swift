import SwiftUI

/// Three palettes, and they are now actually three.
///
/// `augusta` and `clubhouse` used to be the same tokens with a nav bar bolted on
/// one of them, which is why they read as identical everywhere except the top
/// forty points of the screen. Augusta is unchanged — green-led, cream ground,
/// green band. Clubhouse is the one that moved: same cream ground, but slate
/// blue carries the accents instead of green, so the two are distinguishable at
/// a glance rather than by hunting for the difference.
///
/// Theme is display state, not behaviour, so it deliberately does **not** live in
/// `Config` and never touches `ConfigSync`. `ConfigSync.push` fires on every
/// config change and `updateApplicationContext` is a single latest-value slot —
/// putting a phone-only preference there would dirty the slot the detector
/// settings ride on, every time a theme is tapped. The watch has no palette and
/// no use for this. The "config crosses via ConfigSync, never UserDefaults" rule
/// exists because the watch was silently running on default *settings*; a
/// phone-local appearance choice isn't that.
enum Theme: String, CaseIterable, Identifiable {
    case pines      // dark  — evening under the pines
    case clubhouse  // light — cream ground, slate blue accents
    case augusta    // light — cream ground, green accents, green band

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pines:     return "Pines"
        case .clubhouse: return "Clubhouse"
        case .augusta:   return "Augusta"
        }
    }

    var blurb: String {
        switch self {
        case .pines:     return "Deep green, warm cream text. Easiest on the eyes at dusk."
        case .clubhouse: return "Cream page, white cards, slate blue throughout. Cooler and quieter."
        case .augusta:   return "Cream page, Augusta green throughout, green bar across the top."
        }
    }

    var isLight: Bool { self != .pines }
    /// Augusta wears the band as part of its identity. The other two can opt in.
    var bandIsFixed: Bool { self == .augusta }
    var colorScheme: ColorScheme { isLight ? .light : .dark }

    // MARK: Tokens
    //
    // Contrast against each theme's own ground, all clearing WCAG AA:
    //   pines      bone 13.3:1 · muted 7.4:1 · turf 8.8:1 · accent 7.9:1 · amber 14.6:1
    //   clubhouse  bone 13.5:1 · muted 4.7:1 · turf 6.3:1 · accent 5.1:1 · alert 6.0:1

    /// Page ground.
    var dusk: Color {
        isLight ? Color(red: 0.969, green: 0.957, blue: 0.941)   // Clubhouse Cream
                : Color(red: 0.098, green: 0.208, blue: 0.149)   // Pine
    }
    /// Card surface, one step off the ground.
    var panel: Color {
        isLight ? Color(red: 1.000, green: 1.000, blue: 1.000)   // White
                : Color(red: 0.110, green: 0.286, blue: 0.196)   // Loblolly
    }
    /// Primary text.
    var bone: Color {
        isLight ? Color(red: 0.145, green: 0.157, blue: 0.165)   // Charcoal
                : Color(red: 0.969, green: 0.957, blue: 0.941)   // Clubhouse Cream
    }
    /// Secondary text and labels.
    var muted: Color {
        isLight ? Color(red: 0.420, green: 0.435, blue: 0.451)   // Slate
                : Color(red: 0.694, green: 0.702, blue: 0.702)   // Stone
    }
    /// Positive readouts, and the tab-bar tint.
    /// New Growth is 8.8:1 on pine but only 1.4:1 on cream, so the light theme
    /// takes Augusta Green here instead.
    var turf: Color {
        switch self {
        case .pines:     return Color(red: 0.753, green: 0.863, blue: 0.561)  // New Growth
        case .augusta:   return Color(red: 0.000, green: 0.404, blue: 0.278)  // Augusta Green
        case .clubhouse: return Color(red: 0.161, green: 0.322, blue: 0.451)  // Slate Blue, deep
        }
    }
    /// The second colour, whichever way round the theme runs it. In Augusta the
    /// lead is green and this is slate blue; in Clubhouse they swap, which is
    /// what finally makes the two light themes tell apart at a glance. Carries
    /// non-positive emphasis: chart reference lines, the "this is an example"
    /// marker.
    var accent: Color {
        switch self {
        case .pines:     return Color(red: 0.576, green: 0.702, blue: 0.796)  // Slate Blue, lifted
        case .augusta:   return Color(red: 0.278, green: 0.408, blue: 0.522)  // Slate Blue
        case .clubhouse: return Color(red: 0.000, green: 0.404, blue: 0.278)  // Augusta Green
        }
    }
    /// Masters Yellow. Fills only — dots, banners, page indicators — where it
    /// sits as a shape beside text rather than carrying meaning as text itself.
    var amber: Color { Color(red: 0.988, green: 0.890, blue: 0.000) }
    /// Attention *text*: warnings, "not taught yet". Yellow is unreadable on
    /// cream at 1.5:1, so the light theme uses crimson.
    var alert: Color {
        isLight ? Color(red: 0.729, green: 0.047, blue: 0.184)   // Crimson
                : Color(red: 0.988, green: 0.890, blue: 0.000)   // Masters Yellow
    }
    /// The swing trace on the ensemble chart — a thin line, so it needs to hold
    /// up against the ground on its own.
    var trace: Color {
        switch self {
        case .pines:     return Color(red: 0.988, green: 0.890, blue: 0.000)  // Masters Yellow
        case .augusta:   return Color(red: 0.000, green: 0.404, blue: 0.278)  // Augusta Green
        case .clubhouse: return Color(red: 0.161, green: 0.322, blue: 0.451)  // Slate Blue, deep
        }
    }

    // MARK: Persistence — phone-local, deliberately outside Config.

    private static let key = "groove.theme"
    private static let bandKey = "groove.theme.band"

    static var stored: Theme {
        Theme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .pines
    }
    static func store(_ theme: Theme) {
        UserDefaults.standard.set(theme.rawValue, forKey: key)
    }

    /// The green header band, independent of palette.
    static var storedBand: Bool { UserDefaults.standard.bool(forKey: bandKey) }
    static func storeBand(_ on: Bool) { UserDefaults.standard.set(on, forKey: bandKey) }
}

/// The one piece of global state the palette reads. The token accessors below are
/// computed, so every render picks up the current value; `RootView` hangs an
/// `.id()` on the tab tree to force that render. `PhoneController` owns the
/// live session, so rebuilding the tree can't disturb one in progress.
enum Palette {
    static var theme: Theme = .stored
    static var showsBand: Bool = Theme.storedBand
}

// MARK: - Palette
//
// Declared on the ShapeStyle-constrained extension rather than on Color directly
// so implicit member lookup works in both positions: `Color.dusk` for a typed
// Color, and `.foregroundStyle(.muted)` / `.tint(.turf)` where the parameter is
// `some ShapeStyle`. This is how SwiftUI exposes `.red` itself.

extension ShapeStyle where Self == Color {
    static var dusk:   Color { Palette.theme.dusk }
    static var panel:  Color { Palette.theme.panel }
    static var bone:   Color { Palette.theme.bone }
    static var muted:  Color { Palette.theme.muted }
    static var turf:   Color { Palette.theme.turf }
    static var accent: Color { Palette.theme.accent }
    static var amber:  Color { Palette.theme.amber }
    static var alert:  Color { Palette.theme.alert }
    static var trace:  Color { Palette.theme.trace }

    /// Filled buttons and active state. Follows the theme's lead colour, so a
    /// Clubhouse button is slate blue and an Augusta one is green — otherwise
    /// every primary action would still read as Augusta whatever you picked.
    static var fairway: Color {
        Palette.theme == .clubhouse
            ? Color(red: 0.161, green: 0.322, blue: 0.451)   // Slate Blue, deep
            : Color(red: 0.000, green: 0.404, blue: 0.278)   // Augusta Green
    }
    /// Crimson — destructive fills.
    static var crimson: Color { Color(red: 0.729, green: 0.047, blue: 0.184) }
    /// Label colour on a green, crimson or slate fill, in every theme.
    static var cream:   Color { Color(red: 0.969, green: 0.957, blue: 0.941) }
    /// Label colour on a yellow fill, in every theme.
    static var ink:     Color { Color(red: 0.145, green: 0.157, blue: 0.165) }
}

extension View {
    /// Solid green nav bar. Independent of palette now — it's a switch, not a theme.
    @ViewBuilder func themedNavBar() -> some View {
        if Palette.theme.bandIsFixed || Palette.showsBand {
            self.toolbarBackground(Palette.theme.turf, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }
}
