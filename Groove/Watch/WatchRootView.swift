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
        case .armed:      return String(format: "routine matched · %.2f", c.armConfidence)
        case .swinging:   return "audio ducked"
        case .recovering: return "logging"
        default:          return c.isRunning ? "audio untouched" : "not running"
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
            // the duck silently never happens. Say so rather than pretend.
            if c.isRunning && !c.phoneReady {
                Text("Open Groove on your phone")
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

            // Swings and tempo are what he's here for. Rehearsal count is a
            // diagnostic, so it sits small and last.
            HStack {
                stat("swings", "\(c.struckCount)")
                Spacer()
                stat("tempo", c.lastTempo > 0 ? String(format: "%.1f", c.lastTempo) : "—")
            }
            Text("\(c.rehearsalCount) rehearsals")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

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
