import SwiftUI

/// Two palettes, and a separate switch for the green header band.
///
/// There used to be three cases. `augusta` was `clubhouse` plus a nav bar, which
/// is why the two read as identical on device — they were, everywhere except the
/// top forty points of the screen. Presenting a variant as a peer of a real
/// palette is what made the choice feel empty, so the band is now its own toggle
/// and the light theme got a genuine second accent instead.
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
    case pines      // dark — evening under the pines
    case clubhouse  // light — cream, white, slate blue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pines:     return "Pines"
        case .clubhouse: return "Clubhouse"
        }
    }

    var blurb: String {
        switch self {
        case .pines:     return "Deep green, warm cream text. Easiest on the eyes at dusk."
        case .clubhouse: return "Cream page, white cards, slate blue accents. Most readable in daylight."
        }
    }

    var isLight: Bool { self == .clubhouse }
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
        isLight ? Color(red: 0.000, green: 0.404, blue: 0.278)   // Augusta Green
                : Color(red: 0.753, green: 0.863, blue: 0.561)   // New Growth
    }
    /// The contrasting third colour. Cool against cream and green — it reads as
    /// a different family without shouting, which is the whole point. Carries
    /// non-positive emphasis: selected state, chart reference lines, the "this
    /// is an example" marker.
    var accent: Color {
        isLight ? Color(red: 0.278, green: 0.408, blue: 0.522)   // Slate Blue
                : Color(red: 0.576, green: 0.702, blue: 0.796)   // Slate Blue, lifted
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
        isLight ? Color(red: 0.000, green: 0.404, blue: 0.278)   // Augusta Green
                : Color(red: 0.988, green: 0.890, blue: 0.000)   // Masters Yellow
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

    /// Constant across themes — these are always used as a fill, or as text on
    /// top of one, so they don't move with the ground.
    /// Augusta Green — filled buttons and active state.
    static var fairway: Color { Color(red: 0.000, green: 0.404, blue: 0.278) }
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
        if Palette.showsBand {
            self.toolbarBackground(Color.fairway, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }
}
