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

            // Swings and tempo are what you are here for. Practice-swing count is
            // a diagnostic, so it sits small and last.
            HStack {
                stat(c.discipline.countWord, "\(c.struckCount)")
                Spacer()
                stat("tempo", c.lastTempo > 0 ? String(format: "%.1f", c.lastTempo) : "—")
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

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 17, weight: .bold, design: .rounded))
        }
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
            HStack {
                stat("swings", "24")
                Spacer()
                stat("tempo", "3.0")
            }
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
            Text(v).font(.system(size: 17, weight: .bold, design: .rounded))
        }
    }
}
