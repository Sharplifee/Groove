import SwiftUI

// The palette moved to Theme.swift so it can change at runtime. The
// ShapeStyle-extension trick that makes both `Color.dusk` and
// `.foregroundStyle(.muted)` resolve is documented there.

// MARK: - Root

struct RootView: View {
    @StateObject private var c = PhoneController()

    /// Tab selection lives here, on the parent, so it survives the `.id()` below
    /// rebuilding the tab tree — otherwise changing theme in Setup would bounce
    /// you back to Range.
    @State private var tab = 0

    var body: some View {
        Group {
            if !c.config.hasOnboarded {
                OnboardingView(c: c)
            } else {
                TabView(selection: $tab) {
                    RangeView(c: c).tabItem { Label("Range", systemImage: "flag.circle") }
                        .tag(0)
                    ProfileView(c: c).tabItem { Label("Profile", systemImage: "chart.xyaxis.line") }
                        .tag(1)
                    SetupView(c: c).tabItem { Label("Setup", systemImage: "slider.horizontal.3") }
                        .tag(2)
                }
            }
        }
        // The palette is read through computed statics, which SwiftUI can't see as
        // a dependency — so switching theme has to force the subtree to re-render.
        // Safe here: the live session lives in `c`, a StateObject owned by this
        // view, so nothing session-scoped is torn down.
        .id(c.theme)
        // Interactive elements take turf — New Growth on pine (8.8:1), Augusta
        // Green on cream (6.3:1). Amber stays reserved for live state.
        .tint(.turf)
        .preferredColorScheme(c.theme.colorScheme)
        .overlay(alignment: .bottom) {
            if let deleted = c.recentlyDeleted { UndoToast(c: c, swing: deleted) }
        }
        .animation(.snappy, value: c.recentlyDeleted?.id)
    }
}

// MARK: - Range
//
// Deliberately NOT a live dashboard. During a session this phone is in a back
// pocket and cannot be looked at. This is what you see before you start and
// after you finish; the watch is the only live surface.

struct RangeView: View {
    @ObservedObject var c: PhoneController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if c.isDemoMode { DemoBanner() }
                    if c.isSessionLive { liveBanner } else { readyBanner }

                    if c.isSessionLive {
                        Card("while you're out there") {
                            Bullet("Your watch is running the session.")
                            Bullet("Audio drops when you start a real swing.")
                            Bullet("Come back here when you're done.")
                        }
                    } else if let last = c.sessions.first {
                        SessionCard(session: last, isLatest: true)
                    } else {
                        EmptyState(icon: "flag.circle",
                                   title: "No sessions yet",
                                   message: "Open Groove on your watch and press Start. Pocket this phone and go hit balls.")
                    }

                    if let blocker = c.permissions.blocker {
                        Card("this won't run yet") {
                            Text(blocker).font(.footnote).foregroundStyle(.muted)
                            Button("Open Settings") { c.openSettings() }
                                .buttonStyle(Primary())
                        }
                    }

                    Card("before you start") {
                        Bullet("Leave this app open and pocket the phone. If it's fully quit, the watch can't reach it and your audio won't duck.")
                        Bullet("It holds a silent audio session while you're out there — that's what stops iOS suspending it in your pocket.")
                        if c.routeUnavailable {
                            Text("No earbuds connected — it'll fall back to the phone mic, which is muffled in a pocket.")
                                .font(.footnote).foregroundStyle(.alert)
                        }
                        if c.config.hasCalibrated && c.config.gateUntilFirstImpact {
                            Text("Your first shot of a session won't duck — it waits until it's seen one real strike.")
                                .font(.caption2).foregroundStyle(.muted)
                        }
                    }

                    Card("setup check") {
                        KV("audio in", c.inputName)
                        KV("input delay", String(format: "%.0f ms", c.measuredLatency * 1000))
                        KV("ducking", c.config.hasCalibrated ? "on" : "off — not calibrated",
                           tint: c.config.hasCalibrated ? .turf : .alert)
                        if !c.config.hasCalibrated {
                            Text("Teach it your routine in Setup to turn ducking on.")
                                .font(.caption2).foregroundStyle(.muted)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.dusk)
            .navigationTitle("Range")
            .themedNavBar()
            .task {
                c.permissions.refresh()
                if c.permissions.microphone == .unknown { await c.permissions.requestAll() }
            }
        }
    }

    private var readyBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch")
                .font(.system(size: 34)).foregroundStyle(.turf)
            Text("Start from your watch")
                .font(.system(size: 19, weight: .heavy, design: .rounded))
            Text("Then pocket this phone.")
                .font(.footnote).foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private var liveBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(Color.alert).frame(width: 9, height: 9)
                Text("Session running").font(.system(size: 17, weight: .heavy, design: .rounded))
            }
            Text("\(c.summary.struckSwings.count) swings so far")
                .font(.footnote).foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Profile

struct ProfileView: View {
    @ObservedObject var c: PhoneController
    @State private var confirmDelete: Swing?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if c.isDemoMode { DemoBanner() }
                    if c.summary.struckSwings.count < 2 {
                        EmptyState(icon: "chart.xyaxis.line",
                                   title: "Nothing to compare yet",
                                   message: "Repeatability needs a handful of swings. Log a session and come back.")
                    } else {
                        Card("repeatability") {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(String(format: "%.1f", c.summary.repeatability))
                                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                                Text("%").font(.title3).foregroundStyle(.muted)
                            }
                            Text(c.summary.repeatabilityVerdict)
                                .font(.footnote).foregroundStyle(.muted)
                            Text("How much your tempo moves between swings. Lower is better.")
                                .font(.caption2).foregroundStyle(.muted)
                        }

                        Card("every swing, stacked on impact") {
                            EnsembleChart(traces: c.summary.struckSwings.map(\.normalizedTrace))
                                .frame(height: 190)
                            Text("A tight band means you're repeating. Where it fans out is where it breaks down.")
                                .font(.caption2).foregroundStyle(.muted)
                        }

                        Card("tempo") {
                            KV("yours", String(format: "%.2f : 1", c.summary.meanTempo))
                            KV("tour reference", "3.00 : 1")
                        }
                    }

                    if !c.sessions.isEmpty {
                        Text("SESSIONS")
                            .font(.system(size: 9.5, design: .monospaced)).kerning(1.6)
                            .foregroundStyle(.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(c.sessions) { s in
                            SessionCard(session: s,
                                        isLatest: s.id == c.sessions.first?.id,
                                        onDelete: { confirmDelete = $0 })
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.dusk)
            .navigationTitle("Profile")
            .themedNavBar()
            .confirmationDialog("Remove this swing?",
                                isPresented: .init(get: { confirmDelete != nil },
                                                   set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let s = confirmDelete { c.delete(s) }
                    confirmDelete = nil
                }
                Button("Keep it", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("It stops counting toward your repeatability. You can undo this.")
            }
        }
    }
}

struct SessionCard: View {
    let session: RangeSession
    var isLatest = false
    var onDelete: ((Swing) -> Void)?
    @State private var expanded = false

    var body: some View {
        Card(isLatest ? "last session"
                      : session.date.formatted(date: .abbreviated, time: .omitted)) {
            HStack(spacing: 22) {
                Stat("swings", "\(session.struckCount)")
                Stat("repeatability",
                     session.struckCount > 1
                     ? String(format: "%.1f%%", session.summary.repeatability)
                     : "—")
            }
            // Rehearsal count is diagnostic, not a score. It reads small.
            Text("\(session.swings.count - session.struckCount) rehearsals filtered out")
                .font(.caption2).foregroundStyle(.muted)

            if onDelete != nil {
                Button(expanded ? "Hide swings" : "Show swings") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.caption).tint(.turf)

                if expanded {
                    ForEach(session.swings.filter(\.struck)) { s in
                        HStack {
                            Text(s.date, style: .time)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.muted)
                            Spacer()
                            Text(String(format: "%.2f", s.metrics.tempoRatio))
                                .font(.system(.caption, design: .monospaced))
                            Button {
                                onDelete?(s)
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.muted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                    Text("Remove a mishit so it stops dragging your number.")
                        .font(.caption2).foregroundStyle(.muted)
                }
            }
        }
    }
}

/// The signature view — every swing overlaid, median and interquartile band on top.
struct EnsembleChart: View {
    let traces: [[Double]]

    var body: some View {
        GeometryReader { geo in
            let valid = traces.filter { !$0.isEmpty }
            if valid.count < 2 {
                Text("A few more swings and the overlay appears here.")
                    .font(.caption).foregroundStyle(.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let n = valid[0].count
                let peak = max(0.5, valid.flatMap { $0 }.max() ?? 1)
                let e = SwingAnalyzer.ensemble(valid)
                let x = { (i: Int) in geo.size.width * Double(i) / Double(n - 1) }
                let y = { (v: Double) in geo.size.height * (1 - min(1, v / peak)) }

                ZStack {
                    ForEach(Array(valid.enumerated()), id: \.offset) { _, tr in
                        Path { p in
                            for (i, v) in tr.enumerated() {
                                i == 0 ? p.move(to: .init(x: x(i), y: y(v)))
                                       : p.addLine(to: .init(x: x(i), y: y(v)))
                            }
                        }.stroke(Color.trace.opacity(0.13), lineWidth: 1)
                    }

                    Path { p in
                        for (i, v) in e.low.enumerated() {
                            i == 0 ? p.move(to: .init(x: x(i), y: y(v)))
                                   : p.addLine(to: .init(x: x(i), y: y(v)))
                        }
                        for i in stride(from: e.high.count - 1, through: 0, by: -1) {
                            p.addLine(to: .init(x: x(i), y: y(e.high[i])))
                        }
                        p.closeSubpath()
                    }.fill(Color.trace.opacity(0.18))

                    Path { p in
                        for (i, v) in e.median.enumerated() {
                            i == 0 ? p.move(to: .init(x: x(i), y: y(v)))
                                   : p.addLine(to: .init(x: x(i), y: y(v)))
                        }
                    }.stroke(Color.trace, lineWidth: 2.2)

                    let ix = geo.size.width * SwingAnalyzer.tracePre
                        / (SwingAnalyzer.tracePre + SwingAnalyzer.tracePost)
                    Path { p in
                        p.move(to: .init(x: ix, y: 0))
                        p.addLine(to: .init(x: ix, y: geo.size.height))
                    }.stroke(Color.bone.opacity(0.45),
                             style: .init(lineWidth: 1, dash: [3, 4]))
                }
            }
        }
        .accessibilityLabel("Every swing overlaid and aligned on impact")
    }
}

// MARK: - Setup

struct SetupView: View {
    @ObservedObject var c: PhoneController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card("appearance") {
                        Picker("Theme", selection: Binding(
                            get: { c.theme },
                            set: { c.theme = $0 })) {
                                ForEach(Theme.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        Text(c.theme.blurb)
                            .font(.caption).foregroundStyle(.muted)
                    }

                    Card("you") {
                        Picker("You play", selection: $c.config.handedness) {
                            Text("Right").tag(Handedness.right); Text("Left").tag(Handedness.left)
                        }.pickerStyle(.segmented)

                        Picker("Watch on", selection: $c.config.watchWrist) {
                            Text("Left").tag(Wrist.left); Text("Right").tag(Wrist.right)
                        }.pickerStyle(.segmented)

                        Picker("Phone pocket", selection: $c.config.pocket) {
                            Text("Back R").tag(Pocket.backRight)
                            Text("Back L").tag(Pocket.backLeft)
                            Text("None").tag(Pocket.none)
                        }.pickerStyle(.segmented)

                        Text(c.config.watchIsLeadWrist
                             ? "Reading your lead wrist."
                             : "Reading your trail wrist — transition looks very different from there.")
                            .font(.caption).foregroundStyle(.muted)
                    }

                    Card("when to duck") {
                        Picker("Sensitivity", selection: $c.config.sensitivity) {
                            Text("More").tag(Sensitivity.eager)
                            Text("Balanced").tag(Sensitivity.balanced)
                            Text("Certain").tag(Sensitivity.strict)
                        }.pickerStyle(.segmented)
                        Text(c.config.sensitivity.label)
                            .font(.system(size: 13, weight: .semibold))
                        Text(c.config.sensitivity.detail)
                            .font(.caption).foregroundStyle(.muted)
                    }

                    Card("how long to hold") {
                        Text("\(c.config.tailSeconds, specifier: "%.1f") seconds after the ball")
                            .font(.system(size: 13, weight: .semibold))
                        Slider(value: $c.config.tailSeconds, in: 0.3...1.5, step: 0.1)
                        Text("Coming back the instant you make contact steps on the strike you opened the mic to hear.")
                            .font(.caption).foregroundStyle(.muted)
                    }

                    Card("where you listen") {
                        Picker("Route", selection: $c.config.route) {
                            Text("Earbuds").tag(AudioRoute.earbuds)
                            Text("Phone mic").tag(AudioRoute.phoneMic)
                        }.pickerStyle(.segmented)
                        KV("current input", c.inputName)
                        Text("Any brand works — Bluetooth, wired, or USB-C all expose a mic.")
                            .font(.caption).foregroundStyle(.muted)
                        Text("A separate paired device isn't built yet. It's in the architecture but nothing implements it, so it's not offered here.")
                            .font(.caption2).foregroundStyle(.muted)
                    }

                    Card("routine") {
                        KV("calibrated", c.config.hasCalibrated ? "yes" : "no",
                           tint: c.config.hasCalibrated ? .turf : .alert)
                        if let r = c.calibrationResult {
                            SeparationBar(real: r.meanRealConfidence,
                                          rehearsal: r.meanRehearsalConfidence)
                        }
                        Button("Teach it again") { c.beginCalibration() }
                            .buttonStyle(Primary())
                        Text("Worth redoing if you change your pre-shot routine.")
                            .font(.caption2).foregroundStyle(.muted)
                    }

                    Card("your data") {
                        KV("swings stored", "\(c.swings.count)")
                        if let url = c.exportURL() {
                            ShareLink(item: url) {
                                Text("Export everything")
                                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .frame(maxWidth: .infinity).padding(13)
                                    .background(Color.fairway, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        Text("Full JSON including every raw trace, for your own analysis.")
                            .font(.caption2).foregroundStyle(.muted)
                    }

                    Card("what this can't do") {
                        Bullet("No carry, spin, or face angle — it measures your body, not the ball.")
                        Bullet("Impact timing is accurate to about 10 ms.")
                        Bullet("Your watch's sensor saturates on hard strikes, so peak numbers are a floor.")
                    }
                }
                .padding(16)
            }
            .background(Color.dusk)
            .navigationTitle("Setup")
            .themedNavBar()
        }
    }
}

// MARK: - Shared pieces

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 9.5, design: .monospaced))
                .kerning(1.6).foregroundStyle(.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 15))
    }
}

/// Sample data must never be mistaken for a real session.
struct DemoBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye").font(.system(size: 12))
            Text("Sample data — not your swings")
                .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(Color.ink)
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color.amber, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyState: View {
    let icon: String, title: String, message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.muted)
            Text(title).font(.system(size: 17, weight: .heavy, design: .rounded))
            Text(message).font(.footnote).foregroundStyle(.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 20)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.muted).frame(width: 4, height: 4).padding(.top, 6)
            Text(text).font(.footnote).foregroundStyle(.muted)
        }
    }
}

struct Stat: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 10, design: .monospaced)).foregroundStyle(.muted)
            Text(v).font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.bone)
        }
    }
}

struct KV: View {
    let k: String, v: String; var tint: Color = .bone
    init(_ k: String, _ v: String, tint: Color = .bone) { self.k = k; self.v = v; self.tint = tint }
    var body: some View {
        HStack {
            Text(k).font(.system(size: 11, design: .monospaced)).foregroundStyle(.muted)
            Spacer()
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(tint)
        }
    }
}

/// Buttons are green; amber means the app is doing something. Crimson is reserved
/// for destructive only — it never doubles as a recording indicator.
struct Primary: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.cream)
            .frame(maxWidth: .infinity).padding(13)
            .background(destructive ? Color.crimson : Color.fairway,
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct UndoToast: View {
    @ObservedObject var c: PhoneController
    let swing: Swing

    var body: some View {
        HStack {
            Text("Swing removed").font(.footnote)
            Spacer()
            Button("Undo") { c.undoDelete() }
                .font(.footnote.bold()).tint(.turf)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.panel, in: Capsule())
        .overlay(Capsule().stroke(Color.muted.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 60)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            try? await Task.sleep(for: .seconds(6))
            c.clearUndo()
        }
    }
}

@main
struct GrooveApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}
