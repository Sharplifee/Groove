import SwiftUI

// MARK: - Type
//
// Three roles, one scale, defined once.
//
// Everything used to be SF Rounded at assorted weights, which is exactly why it
// read as a default SwiftUI app. Rounded now does one job — display figures and
// headings, where its character is the point. Body copy is the standard text
// face, because rounded at paragraph length looks like a toy. Numbers that
// update live are monospaced so digits don't jitter as they change.

enum Face {
    /// Headings and hero figures. Character lives here and nowhere else.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// Body, labels, everything the eye reads as a sentence.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Readouts. Fixed advance width so a changing value doesn't shift layout.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Font {
    /// Hero number — the one figure a screen is built around.
    static var grooveHero:     Font { Face.display(52) }
    /// Screen and card headline.
    static var grooveTitle:    Font { Face.display(26) }
    static var grooveHeadline: Font { Face.display(18) }
    static var grooveSubhead:  Font { Face.display(15, .bold) }
    /// Body copy.
    static var grooveBody:     Font { Face.text(15) }
    static var grooveCallout:  Font { Face.text(13.5) }
    static var grooveCaption:  Font { Face.text(12) }
    /// Readouts.
    static var grooveFigure:   Font { Face.mono(26, .semibold) }
    static var grooveReadout:  Font { Face.mono(13) }
    /// Section eyebrow — the small tracked label above a group.
    static var grooveEyebrow:  Font { Face.mono(10, .medium) }
}

// MARK: - Spacing, radius, elevation
//
// One scale. Card padding used to drift by a few points from screen to screen,
// which is the sort of thing nobody names but everybody feels.

enum Space {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

enum Radius {
    static let small: CGFloat = 10
    static let card:  CGFloat = 16
    static let large: CGFloat = 22
}

enum Elevation {
    /// Cards sit one step off the ground. Light theme needs the shadow to read
    /// as raised; the dark theme already separates by value alone.
    static var card: Color { Palette.theme.isLight ? .black.opacity(0.05) : .clear }
    static let cardRadius: CGFloat = 10
    static let cardY: CGFloat = 2
}

// MARK: - Motion
//
// Defined once so nothing pops into place.

enum Motion {
    /// Screen and state transitions.
    static let transition: Animation = .spring(response: 0.38, dampingFraction: 0.86)
    /// A value changing in place.
    static let value: Animation = .spring(response: 0.28, dampingFraction: 0.9)
    /// Charts drawing in on appear.
    static let draw: Animation = .easeOut(duration: 0.65)
    /// Toasts and banners.
    static let toast: Animation = .spring(response: 0.32, dampingFraction: 0.82)
}

// MARK: - Icons
//
// One set, one weight, named by meaning rather than by symbol. Picking symbols
// ad hoc per screen is how an app ends up with four different chart glyphs.

enum Icon {
    static let today     = "sun.horizon"
    static let form      = "waveform.path.ecg"
    static let setup     = "slider.horizontal.3"
    static let watch     = "applewatch"
    static let session   = "figure.golf"
    static let sample    = "eye"
    static let tempo     = "metronome"
    static let sequence  = "arrow.left.arrow.right"
    static let repeatable = "target"
    static let warning   = "exclamationmark.triangle"
    static let remove    = "minus.circle"
    static let paired    = "ipad.and.iphone"
}

// MARK: - Components
//
// Every screen composes from these and nothing else. If a screen needs something
// new, it gets added here first.

/// The standard container. One padding value, one radius, one shadow.
struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let title {
                Text(title.uppercased())
                    .font(.grooveEyebrow).kerning(1.5)
                    .foregroundStyle(.muted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: Radius.card))
        .shadow(color: Elevation.card,
                radius: Elevation.cardRadius, y: Elevation.cardY)
    }
}

/// The tracked label above a group of cards.
struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.grooveEyebrow).kerning(1.6)
            .foregroundStyle(.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.s)
    }
}

/// A labelled figure. The number leads, the label supports it.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color?

    init(_ label: String, _ value: String, unit: String? = nil, tint: Color? = nil) {
        self.label = label; self.value = value; self.unit = unit; self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.grooveFigure)
                    .foregroundStyle(tint ?? Color.bone)
                if let unit {
                    Text(unit).font(.grooveCaption).foregroundStyle(.muted)
                }
            }
            Text(label)
                .font(.grooveCaption)
                .foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit ?? "")")
    }
}

/// A key on the left, a value on the right.
struct Row: View {
    let key: String
    let value: String
    var tint: Color?

    init(_ key: String, _ value: String, tint: Color? = nil) {
        self.key = key; self.value = value; self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.grooveCallout).foregroundStyle(.muted)
            Spacer(minLength: Space.m)
            Text(value)
                .font(.grooveReadout)
                .foregroundStyle(tint ?? Color.bone)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Explanatory line inside a card. Never a bullet list of three words.
struct Note: View {
    let text: String
    var tint: Color?
    init(_ text: String, tint: Color? = nil) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.grooveCaption)
            .foregroundStyle(tint ?? Color.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle().fill(Color.muted)
                .frame(width: 4, height: 4).padding(.top, 7)
            Text(text)
                .font(.grooveCallout).foregroundStyle(.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Used for real emptiness only. The first-launch path never reaches one —
/// a fresh install shows a worked example instead.
struct EmptyState: View {
    let icon: String, title: String, message: String
    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.muted)
            Text(title).font(.grooveHeadline).foregroundStyle(.bone)
            Text(message)
                .font(.grooveCallout).foregroundStyle(.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl).padding(.horizontal, Space.xl)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

/// Standing marker. Slate blue, not yellow — this is information, not a warning,
/// and yellow was reading as "something is wrong".
struct Banner: View {
    let icon: String
    let text: String
    var tint: Color = .accent

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.grooveCaption.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.cream)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s + 2)
        .frame(maxWidth: .infinity)
        .background(tint, in: RoundedRectangle(cornerRadius: Radius.small))
    }
}

struct PrimaryButton: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.grooveSubhead)
            .foregroundStyle(Color.cream)
            .frame(maxWidth: .infinity).padding(Space.m + 2)
            .background(destructive ? Color.crimson : Color.fairway,
                        in: RoundedRectangle(cornerRadius: Radius.small))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.value, value: configuration.isPressed)
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.grooveSubhead)
            .foregroundStyle(Color.bone)
            .frame(maxWidth: .infinity).padding(Space.m + 2)
            .background(
                RoundedRectangle(cornerRadius: Radius.small)
                    .stroke(Color.muted.opacity(0.35), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Motion.value, value: configuration.isPressed)
    }
}

/// One question, its answer options, and room for the question to be a real
/// sentence rather than a two-word stub.
struct Question<T: Hashable, Content: View>: View {
    let title: String
    var help: String?
    @Binding var selection: T
    @ViewBuilder var options: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.grooveSubhead).foregroundStyle(.bone)
            Picker(title, selection: $selection) { options }
                .pickerStyle(.segmented)
            if let help {
                Note(help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Chart container — title, the chart, and the sentence that says what to look
/// for. A chart without that sentence is decoration.
struct ChartFrame<Content: View>: View {
    let title: String
    let caption: String
    var height: CGFloat = 190
    @ViewBuilder var content: Content

    var body: some View {
        Card(title) {
            content.frame(height: height)
            Note(caption)
        }
    }
}
