import SwiftUI

// MARK: - Broadcast kit
//
// The presentation language for player data: television-graphics numbers on a
// serious tool. Everything here follows three rules that keep it a training
// aid and not an arcade:
//
//   1. Every pixel is a measurement. Rings, needles, bands and deltas each map
//      to one number the engine produced; nothing decorative pretends to be
//      data.
//   2. Big number first, words second. A scratch player reads "2.94 : 1" faster
//      than a sentence about it — the sentence stays, underneath, for the day
//      the number surprises them.
//   3. Amber is a shape, never text. Same rule as the rest of the app.

// MARK: Score ring

/// The hero. An arc that fills with the session's Groove Score, colour running
/// turf → amber as it climbs, with the number seated in the middle. Animates on
/// arrival because a score that snaps into place reads as a label, and one that
/// sweeps in reads as earned.
struct ScoreRing: View {
    let score: Int
    let verdict: (title: String, detail: String)
    @State private var swept = false

    var body: some View {
        VStack(spacing: Space.m) {
            ZStack {
                Circle()
                    .stroke(Color.bone.opacity(0.10), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: swept ? CGFloat(score) / 100 : 0)
                    .stroke(
                        AngularGradient(
                            colors: [.turf, .turf, .amber],
                            center: .center,
                            startAngle: .degrees(0), endAngle: .degrees(320)),
                        style: .init(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Color.amber.opacity(0.35), radius: 6)
                VStack(spacing: 2) {
                    Text("\(score)")
                        .font(.grooveScore)
                        .foregroundStyle(.bone)
                        .contentTransition(.numericText())
                    Text("GROOVE SCORE")
                        .font(.grooveEyebrow)
                        .foregroundStyle(.muted)
                        .kerning(1.4)
                }
            }
            .frame(width: 168, height: 168)
            .padding(.top, Space.s)

            VStack(spacing: 3) {
                Text(verdict.title)
                    .font(.grooveHeadline).foregroundStyle(.bone)
                Text(verdict.detail)
                    .font(.grooveCallout).foregroundStyle(.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { swept = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Groove score \(score) out of 100. \(verdict.title). \(verdict.detail)")
    }
}

// MARK: Deltas

/// Change against the previous comparable session. The sign convention is
/// handled by the caller — pass `improved`, not raw arithmetic — because
/// repeatability improves downward and everything else improves upward, and
/// that inversion has burned this codebase before.
struct DeltaTag: View {
    let text: String
    let improved: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: improved ? "arrowtriangle.up.fill"
                                       : "arrowtriangle.down.fill")
                .font(.system(size: 8, weight: .bold))
            Text(text).font(.grooveEyebrow.weight(.bold))
        }
        .foregroundStyle(improved ? Color.turf : Color.alert)
        .accessibilityLabel(improved ? "improved by \(text)" : "worse by \(text)")
    }
}

// MARK: Stat tiles

/// Number-first tile for the hero row: eyebrow, big value, optional delta.
struct BroadcastTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var delta: (text: String, improved: Bool)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.grooveEyebrow).foregroundStyle(.muted).kerning(1.1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.grooveStat).foregroundStyle(.bone)
                if let unit { Text(unit).font(.grooveCallout).foregroundStyle(.muted) }
            }
            if let delta {
                DeltaTag(text: delta.text, improved: delta.improved)
            } else {
                // Keeps the three tiles the same height whether or not a
                // previous session exists to compare against.
                Text(" ").font(.grooveEyebrow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Tempo meter

/// Tempo as a needle on a scale, with the reference tempo marked as a band
/// rather than a target — the app's position is that owning *a* tempo beats
/// matching anyone else's, and a band says "neighbourhood" where a bullseye
/// would say "score".
struct TempoMeter: View {
    let value: Double            // player's mean ratio
    let reference: Double        // discipline reference
    let referenceLabel: String

    private var lo: Double { reference * 0.55 }
    private var hi: Double { reference * 1.45 }
    private func x(_ v: Double, _ w: CGFloat) -> CGFloat {
        let t = (min(max(v, lo), hi) - lo) / (hi - lo)
        return CGFloat(t) * w
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.bone.opacity(0.10))
                        .frame(height: 6).offset(y: 21)
                    // Reference neighbourhood, ±10%.
                    Capsule()
                        .fill(Color.accent.opacity(0.28))
                        .frame(width: x(reference * 1.1, w) - x(reference * 0.9, w), height: 6)
                        .offset(x: x(reference * 0.9, w), y: 21)
                    Rectangle()
                        .fill(Color.accent)
                        .frame(width: 2, height: 14)
                        .offset(x: x(reference, w) - 1, y: 17)
                    // The player's needle: amber dot, value riding above it.
                    VStack(spacing: 2) {
                        Text(String(format: "%.2f", value))
                            .font(.grooveReadout.weight(.heavy)).foregroundStyle(.bone)
                        Circle().fill(Color.amber)
                            .frame(width: 11, height: 11)
                            .shadow(color: Color.amber.opacity(0.6), radius: 4)
                    }
                    .position(x: x(value, w), y: 14)
                }
            }
            .frame(height: 36)
            HStack {
                Text(String(format: "%.1f", lo))
                Spacer()
                Text("\(referenceLabel.uppercased()) \(String(format: "%.1f", reference))")
                    .foregroundStyle(.accent)
                Spacer()
                Text(String(format: "%.1f", hi))
            }
            .font(.grooveEyebrow).foregroundStyle(.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your tempo \(String(format: "%.2f", value)) to one, against a \(referenceLabel) of \(String(format: "%.1f", reference)) to one")
    }
}

// MARK: Sequence bar

/// Hips-versus-hands on a timeline. Centre tick is "together"; the dot lands
/// where the hips actually fired relative to the hands, so the kinematic
/// sequence reads as a position instead of a signed number to decode.
struct SequenceBar: View {
    let leadMs: Double
    private let span: Double = 60   // ±60 ms window

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { g in
                let w = g.size.width
                let t = (min(max(leadMs, -span), span) + span) / (2 * span)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.bone.opacity(0.10))
                        .frame(height: 6).offset(y: 15)
                    // Good half: hips first.
                    Capsule().fill(Color.turf.opacity(0.22))
                        .frame(width: w / 2, height: 6)
                        .offset(x: w / 2, y: 15)
                    Rectangle().fill(Color.bone.opacity(0.4))
                        .frame(width: 2, height: 14).offset(x: w / 2 - 1, y: 11)
                    Circle()
                        .fill(leadMs > 0 ? Color.turf : Color.alert)
                        .frame(width: 12, height: 12)
                        .shadow(color: (leadMs > 0 ? Color.turf : Color.alert).opacity(0.5),
                                radius: 4)
                        .position(x: CGFloat(t) * w, y: 18)
                }
            }
            .frame(height: 30)
            HStack {
                Text("HANDS FIRST")
                Spacer()
                Text("TOGETHER")
                Spacer()
                Text("HIPS FIRST")
            }
            .font(.grooveEyebrow).foregroundStyle(.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(leadMs > 0
            ? "Your hips lead your hands by \(Int(leadMs)) milliseconds"
            : "Your hands lead your hips by \(Int(-leadMs)) milliseconds")
    }
}

// MARK: Trend area

/// The improvement line with an area fill under it and the newest point picked
/// out in amber. Values arrive already oriented so that up means better.
struct TrendArea: View {
    let points: [Double]

    var body: some View {
        GeometryReader { g in
            let lo = (points.min() ?? 0) - 0.5
            let hi = (points.max() ?? 1) + 0.5
            let span = max(0.1, hi - lo)
            let x = { (i: Int) in g.size.width * Double(i) / Double(max(1, points.count - 1)) }
            let y = { (v: Double) in g.size.height * (1 - (v - lo) / span) }

            ZStack {
                Path { p in
                    p.move(to: .init(x: 0, y: g.size.height))
                    for (i, v) in points.enumerated() { p.addLine(to: .init(x: x(i), y: y(v))) }
                    p.addLine(to: .init(x: g.size.width, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.turf.opacity(0.30), Color.turf.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    for (i, v) in points.enumerated() {
                        i == 0 ? p.move(to: .init(x: x(i), y: y(v)))
                               : p.addLine(to: .init(x: x(i), y: y(v)))
                    }
                }
                .stroke(Color.turf, style: .init(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { i, v in
                    Circle()
                        .fill(i == points.count - 1 ? Color.amber : Color.turf)
                        .frame(width: i == points.count - 1 ? 8 : 5,
                               height: i == points.count - 1 ? 8 : 5)
                        .shadow(color: i == points.count - 1 ? Color.amber.opacity(0.6) : .clear,
                                radius: 4)
                        .position(x: x(i), y: y(v))
                }
            }
        }
        .accessibilityLabel("Your groove score across recent sessions")
    }
}

// MARK: Score badge

/// The small score chip on a session row — the same number as the ring, sized
/// for a scorecard line.
struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.grooveReadout.weight(.heavy))
            .foregroundStyle(.bone)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.amber.opacity(0.20)))
            .overlay(Capsule().stroke(Color.amber.opacity(0.55), lineWidth: 1))
            .accessibilityLabel("Groove score \(score)")
    }
}
