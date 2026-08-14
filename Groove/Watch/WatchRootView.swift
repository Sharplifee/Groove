import SwiftUI

struct WatchRootView: View {
    @StateObject private var c = WatchController()

    private var accent: Color {
        switch c.state {
        case .armed:                return .green
        case .swinging, .recovering: return .orange
        default:                     return .secondary
        }
    }

    private var label: String {
        switch c.state {
        case .watching, .settling: return "WATCHING"
        case .armed:               return "SET"
        case .swinging:            return "SWING"
        case .recovering:          return "…"
        }
    }

    private var sub: String {
        switch c.state {
        case .armed:      return "ready"
        case .swinging:   return "music down"
        case .recovering: return "logging"
        default:          return c.isRunning ? "music untouched" : "not running"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GROOVE").font(.system(size: 14, weight: .heavy, design: .rounded))
                Spacer()
                if c.isRunning {
                    Circle().fill(accent).frame(width: 7, height: 7)
                }
            }

            Text(label)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .contentTransition(.opacity)

            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)

            // Without the phone app alive, events queue instead of firing and
            // the music never drops. Say so rather than pretend.
            if c.isRunning && !c.phoneReady {
                Text("Phone not responding")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if c.unsentSwings > 0 {
                Text("\(c.unsentSwings) waiting to sync")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let problem = c.blocker {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            // The in-round HUD. One glance between shots answers the two
            // questions that matter mid-session: what did that one do, and am
            // I repeating. Count and last tempo run big; the strip shows the
            // last handful of tempos against the session mean, so a wild one
            // sticks out as a tall or short bar without any reading.
            HStack(alignment: .lastTextBaseline) {
                stat(c.discipline.countWord, "\(c.struckCount)")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("TEMPO").font(.system(size: 9)).foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(c.lastTempo > 0 ? String(format: "%.1f", c.lastTempo) : "—")
                            .font(.system(size: 22, weight: .heavy, design: .monospaced))
                            .foregroundStyle(gold)
                            .contentTransition(.numericText())
                        if c.lastTempo > 0 {
                            Text(":1").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if c.tempos.count >= 2 {
                TempoStrip(tempos: Array(c.tempos.suffix(7)))
                    .frame(height: 20)
            }

            Text("\(c.rehearsalCount) practice \(c.discipline.strokeWord)s")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            // Only before a session. Traces from two disciplines must never
            // stack together, so switching mid-session is refused rather than
            // silently mixing a putt into a full-swing ensemble.
            if !c.isRunning {
                Picker("", selection: Binding(get: { c.discipline },
                                              set: { c.discipline = $0 })) {
                    ForEach(Discipline.allCases) { d in
                        Text(d.shortLabel).tag(d)
                    }
                }
                .pickerStyle(.navigationLink)
                .frame(height: 32)
            }

            Button {
                c.isRunning ? c.stop() : c.start()
            } label: {
                Text(c.isRunning ? "End" : "Start").frame(maxWidth: .infinity)
            }
            .tint(c.isRunning ? .red : .green)
        }
        .padding(.horizontal, 4)
        .task { await c.requestAuthorization() }
    }

    private var gold: Color { Color(red: 0.988, green: 0.890, blue: 0.000) }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 22, weight: .heavy, design: .monospaced))
                .contentTransition(.numericText())
        }
    }
}

/// The live consistency strip: one bar per recent swing, height keyed to how
/// far that tempo sat from the session mean. A grooved run reads as a level
/// row; the mishit reads as the bar that broke formation. Green when within
/// ten percent of the mean, orange outside it — no numbers to parse mid-round.
struct TempoStrip: View {
    let tempos: [Double]

    var body: some View {
        let mean = tempos.reduce(0, +) / Double(tempos.count)
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(tempos.enumerated()), id: \.offset) { _, t in
                let dev = mean > 0 ? (t - mean) / mean : 0
                let clamped = max(-0.3, min(0.3, dev))
                Capsule()
                    .fill(abs(dev) <= 0.10 ? Color.green : Color.orange)
                    .frame(width: 7, height: 8 + CGFloat(abs(clamped)) * 36)
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Your recent tempos against this session's average")
    }
}

@main
struct GrooveWatchApp: App {
    var body: some Scene { WindowGroup { WatchRootView() } }
}

// MARK: - Previews
//
// The watch is the only live surface, so these are what actually matter to look
// at — the phone screens are all read-after-the-fact.

#Preview("Watching") { WatchPreview(state: .watching, running: true) }
#Preview("Set") { WatchPreview(state: .armed, running: true) }
#Preview("Swing — music down") { WatchPreview(state: .swinging, running: true) }
#Preview("Idle — not started") { WatchPreview(state: .watching, running: false) }
#Preview("Phone unreachable") { WatchPreview(state: .watching, running: true, phone: false) }

/// Mirrors WatchRootView's layout against fixed values, so each state can be
/// inspected without a paired device or a live session.
struct WatchPreview: View {
    let state: DetectorState
    var running = true
    var phone = true
    var unsent = 0

    private var accent: Color {
        switch state {
        case .armed: return .green
        case .swinging, .recovering: return .orange
        default: return .secondary
        }
    }
    private var label: String {
        switch state {
        case .watching, .settling: return "WATCHING"
        case .armed: return "SET"
        case .swinging: return "SWING"
        case .recovering: return "…"
        }
    }
    private var sub: String {
        switch state {
        case .armed: return "ready"
        case .swinging: return "music down"
        case .recovering: return "logging"
        default: return running ? "music untouched" : "not running"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GROOVE").font(.system(size: 14, weight: .heavy, design: .rounded))
                Spacer()
                if running { Circle().fill(accent).frame(width: 7, height: 7) }
            }
            Text(label).font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if running && !phone {
                Text("Phone not responding")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if unsent > 0 {
                Text("\(unsent) waiting to sync")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(alignment: .lastTextBaseline) {
                stat("swings", "24")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("TEMPO").font(.system(size: 9)).foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text("3.0")
                            .font(.system(size: 22, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Color(red: 0.988, green: 0.890, blue: 0.000))
                        Text(":1").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            TempoStrip(tempos: [3.02, 2.96, 3.05, 2.71, 3.01, 2.98, 3.03])
                .frame(height: 20)
            Text("41 practice swings").font(.system(size: 9)).foregroundStyle(.secondary)
            Button { } label: {
                Text(running ? "End" : "Start").frame(maxWidth: .infinity)
            }
            .tint(running ? .red : .green)
        }
        .padding(.horizontal, 4)
    }


    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 22, weight: .heavy, design: .monospaced))
                .contentTransition(.numericText())
        }
    }
}

