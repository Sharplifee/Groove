import SwiftUI

// The palette lives in Theme.swift; type, spacing and components live in
// DesignSystem.swift. Nothing in this file defines a style of its own — if a
// screen needs something new, it goes in the design system first.

// MARK: - Root

struct RootView: View {
    @StateObject private var c = PhoneController()

    /// Tab selection lives here, on the parent, so it survives the `.id()` below
    /// rebuilding the tab tree — otherwise changing theme in Setup would bounce
    /// you back to the first tab.
    @State private var tab = 0

    var body: some View {
        Group {
            if !c.config.hasOnboarded {
                OnboardingView(c: c)
            } else if c.isPadLayout {
                PairedDeviceView(c: c)
            } else {
                TabView(selection: $tab) {
                    TodayView(c: c)
                        .tabItem { Label("Today", systemImage: Icon.today) }.tag(0)
                    FormView(c: c)
                        .tabItem { Label("Form", systemImage: Icon.form) }.tag(1)
                    SetupView(c: c)
                        .tabItem { Label("Setup", systemImage: Icon.setup) }.tag(2)
                }
            }
        }
        // The palette is read through computed statics, which SwiftUI can't see as
        // a dependency — so switching theme has to force the subtree to re-render.
        // Safe here: the live session lives in `c`, a StateObject owned by this
        // view, so nothing session-scoped is torn down.
        .id("\(c.theme.rawValue)-\(c.showsBand)")
        .tint(.turf)
        .preferredColorScheme(c.theme.colorScheme)
        .overlay(alignment: .bottom) {
            if let deleted = c.recentlyDeleted { UndoToast(c: c, swing: deleted) }
        }
        .animation(Motion.toast, value: c.recentlyDeleted?.id)
    }
}

/// Every screen sits on this, so the ground, padding and scroll behaviour are
/// identical everywhere.
private struct Screen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.m) { content }
                    .padding(Space.l)
                    .padding(.bottom, Space.xxl)
            }
            .background(Color.dusk)
            .navigationTitle(title)
            .themedNavBar()
        }
    }
}

// MARK: - Today
//
// Deliberately NOT a live dashboard. During a session this phone is in a back
// pocket and cannot be looked at. This is what you see before you start and
// after you finish; the watch is the only live surface.
//
// It used to be called "Range", which reads as a rangefinder and says nothing
// about what the screen holds.

struct TodayView: View {
    @ObservedObject var c: PhoneController

    var body: some View {
        Screen(title: "Today") {
            if c.isShowingExample {
                Banner(icon: Icon.sample, text: "This is an example session, not your swings.")
            }

            if c.isSessionLive {
                liveHeader
                Card("while you're out there") {
                    Bullet("Your watch is running the session.")
                    Bullet("Your music drops the moment you start a real swing, and you hear the strike.")
                    Bullet("Come back here when you're done.")
                }
            } else {
                startHeader
                if let last = c.sessions.first {
                    SessionCard(session: last, isLatest: true)
                }
                // Only sessions of the same discipline as the last one. A
                // putting session repeats far tighter than a full-swing session
                // by nature, so plotting them on one line would show a player
                // improving every time they walked to the green and collapsing
                // every time they went back to the range.
                if let latest = c.sessions.first {
                    let d = latest.summary.discipline
                    let comparable = c.sessions
                        .filter { $0.summary.discipline == d }
                        .prefix(8).reversed()
                    if comparable.count > 1 {
                        TrendCard(sessions: Array(comparable), discipline: d)
                    }
                }
            }

            if let blocker = c.permissions.blocker {
                Card("this won't run yet") {
                    Note(blocker, tint: .alert)
                    Button("Open Settings") { c.openSettings() }
                        .buttonStyle(PrimaryButton())
                }
            }

            if !c.config.hasCalibrated {
                Card("teach it your swing") {
                    Note("Until it has watched you hit a few balls, it can't tell a real swing from a rehearsal, so your music won't drop.")
                    Button("Teach it now") { c.beginCalibration() }
                        .buttonStyle(PrimaryButton())
                }
            }
        }
        .task {
            c.permissions.refresh()
            if c.permissions.microphone == .unknown { await c.permissions.requestAll() }
        }
    }

    private var startHeader: some View {
        VStack(spacing: Space.m) {
            Image(systemName: Icon.watch)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.turf)
            Text("Start from your watch")
                .font(.grooveHeadline).foregroundStyle(.bone)
            Text("Then put this phone in your pocket.")
                .font(.grooveCallout).foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: Radius.large))
        .shadow(color: Elevation.card, radius: Elevation.cardRadius, y: Elevation.cardY)
    }

    private var liveHeader: some View {
        VStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                Circle().fill(Color.amber).frame(width: 9, height: 9)
                Text("Session running").font(.grooveHeadline)
            }
            Text("\(c.summary.struckSwings.count) \(c.summary.discipline.countWord) so far")
                .font(.grooveCallout).foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: Radius.large))
        .shadow(color: Elevation.card, radius: Elevation.cardRadius, y: Elevation.cardY)
    }
}

/// Repeatability across recent sessions. Lower is better, so the axis is
/// inverted deliberately — a rising line always means improving.
struct TrendCard: View {
    let sessions: [RangeSession]
    var discipline: Discipline = .fullSwing

    private var values: [Double] {
        sessions.map { $0.summary.repeatability }.filter { $0 > 0 }
    }

    var body: some View {
        if values.count > 1 {
            ChartFrame(title: "are you getting more consistent",
                       caption: "Each point is one \(discipline.label.lowercased()) session. Higher is better — the line rises as you become more repeatable.",
                       height: 120) {
                TrendLine(values: values)
            }
        }
    }
}

private struct TrendLine: View {
    let values: [Double]

    var body: some View {
        GeometryReader { g in
            let lo = (values.min() ?? 0) - 0.5
            let hi = (values.max() ?? 1) + 0.5
            let span = max(0.1, hi - lo)
            let x = { (i: Int) in g.size.width * Double(i) / Double(max(1, values.count - 1)) }
            // Inverted: low repeatability is good, so it plots high.
            let y = { (v: Double) in g.size.height * ((v - lo) / span) }

            ZStack {
                Path { p in
                    for (i, v) in values.enumerated() {
                        i == 0 ? p.move(to: .init(x: x(i), y: y(v)))
                               : p.addLine(to: .init(x: x(i), y: y(v)))
                    }
                }
                .stroke(Color.accent, style: .init(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Circle().fill(Color.accent)
                        .frame(width: 5, height: 5)
                        .position(x: x(i), y: y(v))
                }
            }
        }
        .accessibilityLabel("Repeatability across your recent sessions")
    }
}

// MARK: - Form
//
// The analysis surface. This used to be "Profile" holding one tile that said
// nothing to compare yet.

struct FormView: View {
    @ObservedObject var c: PhoneController
    @State private var confirmDelete: Swing?
    @State private var lens: Discipline = .fullSwing

    /// Disciplines that actually have strokes recorded. No point offering a
    /// putting tab to someone who has only ever hit full shots.
    private var available: [Discipline] { c.summary.disciplinesPresent }

    /// Everything below reads from this, never from the unfiltered summary.
    /// Traces from two disciplines must never share an ensemble — the chart
    /// aligns on index, so a putt and a drive would overlay two different
    /// motions and the difference would read as inconsistency.
    private var view: SessionSummary { c.summary.filtered(to: lens) }

    var body: some View {
        Screen(title: "Form") {
            if c.isShowingExample {
                Banner(icon: Icon.sample, text: "This is an example session, not your swings.")
            }

            if available.count > 1 {
                Picker("Practice", selection: $lens) {
                    ForEach(available) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if view.struckSwings.count < 2 {
                EmptyState(icon: Icon.form,
                           title: "Nothing to compare yet",
                           message: available.isEmpty
                             ? "This fills in once you've hit a handful of balls in a session."
                             : "Not enough \(lens.countWord) yet. Hit a few more and this fills in.")
            } else {
                repeatabilityCard
                ChartFrame(title: "every \(lens.strokeWord), stacked on impact",
                           caption: "Each faint line is one \(lens.strokeWord), lined up on the moment you strike the ball. A tight band means you're repeating. Where it fans out is where it breaks down.") {
                    EnsembleChart(traces: view.struckSwings.map(\.normalizedTrace))
                }
                tempoCard
                // Only offered where hips actually move. In a chip they barely
                // do and in a putt they effectively don't, so a number there
                // would be noise dressed as insight.
                if let lead = view.meanPelvisLead { sequencingCard(lead) }
            }

            if !c.sessions.isEmpty {
                SectionHeader("sessions")
                ForEach(c.sessions) { s in
                    SessionCard(session: s,
                                isLatest: s.id == c.sessions.first?.id,
                                onDelete: { confirmDelete = $0 })
                }
            }
        }
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

    private var repeatabilityCard: some View {
        Card("repeatability") {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(String(format: "%.1f", view.repeatability))
                    .font(.grooveHero).foregroundStyle(.bone)
                Text("%").font(.grooveHeadline).foregroundStyle(.muted)
            }
            Text(view.repeatabilityVerdict)
                .font(.grooveBody).foregroundStyle(.bone)
            Note("How much your timing moves from \(lens.strokeWord) to \(lens.strokeWord). Lower is better — 0% would be the same one every time.")
            if lens == .putting {
                Note("This is the number worth chasing on the green. A missed putt tells you almost nothing about your stroke — the read and the green speed get in the way. Whether you repeated it does.",
                     tint: .accent)
            }
        }
    }

    private var tempoCard: some View {
        Card("tempo") {
            HStack(spacing: Space.l) {
                StatTile("yours", String(format: "%.2f", view.meanTempo), unit: ": 1")
                StatTile(lens.tempoReferenceLabel,
                         String(format: "%.2f", lens.tempoReference),
                         unit: ": 1", tint: .accent)
            }
            Note(lens == .putting
                 ? "How long your backstroke takes compared with your forward stroke. Around two to one is typical — a putt accelerates through the ball rather than releasing into it."
                 : "How long your backswing takes compared with your downswing. There's no right number — yours being the same every time matters more than matching anyone else's.")
        }
    }

    private func sequencingCard(_ lead: Double) -> some View {
        Card("hips and hands") {
            StatTile("your hips lead by",
                     String(format: "%.0f", lead), unit: "ms",
                     tint: lead > 0 ? .turf : .alert)
            Note(lead > 0
                 ? "Your hips start turning before your hands come down, which is the order you want."
                 : "Your hands are arriving before your hips turn. That's the reverse of what most good swings do.")
            Note("Measured from the phone in your pocket, so it only appears when you're carrying it.")
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
            HStack(spacing: Space.l) {
                StatTile(session.summary.discipline.countWord, "\(session.struckCount)")
                StatTile("repeatability",
                         session.struckCount > 1
                         ? String(format: "%.1f", session.summary.repeatability)
                         : "—",
                         unit: session.struckCount > 1 ? "%" : nil)
                StatTile("tempo",
                         session.struckCount > 0
                         ? String(format: "%.2f", session.summary.meanTempo)
                         : "—")
            }

            let rehearsals = session.swings.count - session.struckCount
            if rehearsals > 0 {
                Note("\(rehearsals) rehearsal\(rehearsals == 1 ? "" : "s") ignored — practice swings don't count toward your numbers.")
            }

            if onDelete != nil {
                Button(expanded ? "Hide swings" : "Show swings") {
                    withAnimation(Motion.transition) { expanded.toggle() }
                }
                .font(.grooveCallout.weight(.semibold)).tint(.turf)

                if expanded {
                    ForEach(session.swings.filter(\.struck)) { s in
                        HStack {
                            Text(s.date, style: .time)
                                .font(.grooveReadout).foregroundStyle(.muted)
                            Spacer()
                            Text(String(format: "%.2f", s.metrics.tempoRatio))
                                .font(.grooveReadout).foregroundStyle(.bone)
                            Button { onDelete?(s) } label: {
                                Image(systemName: Icon.remove).foregroundStyle(.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove this swing")
                        }
                        .padding(.vertical, 3)
                    }
                    Note("Remove a mishit so it stops dragging your number down.")
                }
            }
        }
    }
}

/// The signature view — every swing overlaid, median and interquartile band on top.
struct EnsembleChart: View {
    let traces: [[Double]]
    @State private var drawn = false

    var body: some View {
        GeometryReader { geo in
            let valid = traces.filter { !$0.isEmpty }
            if valid.count < 2 {
                Text("A few more swings and the overlay appears here.")
                    .font(.grooveCallout).foregroundStyle(.muted)
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
                    }.stroke(Color.accent.opacity(0.8),
                             style: .init(lineWidth: 1, dash: [3, 4]))

                    Text("impact")
                        .font(.grooveEyebrow).foregroundStyle(.accent)
                        .position(x: min(geo.size.width - 22, ix + 22), y: 9)
                }
                .opacity(drawn ? 1 : 0)
                .onAppear { withAnimation(Motion.draw) { drawn = true } }
            }
        }
        .accessibilityLabel("Every swing overlaid and lined up on the moment of impact")
    }
}

// MARK: - Setup
//
// Ordered by how often each thing is actually touched.

struct SetupView: View {
    @ObservedObject var c: PhoneController

    var body: some View {
        Screen(title: "Setup") {
            youCard
            duckingCard
            routineCard
            appearanceCard
            sampleCard
            dataCard
            limitsCard
        }
    }

    // 1 — the questions that change how a swing reads.
    private var youCard: some View {
        Card("you") {
            Question(title: "Which hand do you play?",
                     selection: $c.config.handedness) {
                Text("Right-handed").tag(Handedness.right)
                Text("Left-handed").tag(Handedness.left)
            }

            Question(title: "Which wrist is your watch on?",
                     selection: $c.config.watchWrist) {
                Text("Left wrist").tag(Wrist.left)
                Text("Right wrist").tag(Wrist.right)
            }

            Question(title: "Which pocket holds your phone?",
                     help: c.config.pocket == .none
                        ? "Without the phone on you, it can't tell whether your hips lead your hands. Everything else still works."
                        : "The phone reads your hips from your pocket.",
                     selection: $c.config.pocket) {
                Text("Back right").tag(Pocket.backRight)
                Text("Back left").tag(Pocket.backLeft)
                Text("Not on me").tag(Pocket.none)
            }
        }
    }

    // 2 — the behaviour most likely to need nudging after a session.
    private var duckingCard: some View {
        Card("when your music drops") {
            Question(title: "How eager should it be?",
                     help: c.config.sensitivity.detail,
                     selection: $c.config.sensitivity) {
                Text("More often").tag(Sensitivity.eager)
                Text("Balanced").tag(Sensitivity.balanced)
                Text("Only when sure").tag(Sensitivity.strict)
            }

            Divider().overlay(Color.muted.opacity(0.2))

            VStack(alignment: .leading, spacing: Space.s) {
                Text("How long to stay quiet after the ball")
                    .font(.grooveSubhead).foregroundStyle(.bone)
                HStack {
                    Slider(value: $c.config.tailSeconds, in: 0.3...1.5, step: 0.1)
                    Text(String(format: "%.1fs", c.config.tailSeconds))
                        .font(.grooveReadout).foregroundStyle(.bone)
                        .frame(width: 42, alignment: .trailing)
                }
                Note("Bringing your music straight back would talk over the strike you were trying to hear.")
            }
        }
    }

    // 3 — set once, revisited only if the routine changes.
    private var routineCard: some View {
        Card("your pre-shot routine") {
            Row("taught", c.config.hasCalibrated ? "Yes" : "Not yet",
                tint: c.config.hasCalibrated ? .turf : .alert)

            if let r = c.calibrationResult {
                SeparationBar(real: r.meanRealConfidence,
                              rehearsal: r.meanRehearsalConfidence)
            }

            if !c.config.hasCalibrated {
                Note("Until it's taught, your music won't drop — it can't yet tell a real swing from a practice one.", tint: .alert)
            }

            Button(c.config.hasCalibrated ? "Teach it again" : "Teach it now") {
                c.beginCalibration()
            }
            .buttonStyle(c.config.hasCalibrated ? AnyButtonStyleBox(SecondaryButton())
                                                : AnyButtonStyleBox(PrimaryButton()))

            Note("Worth redoing if you change how you set up over the ball.")
        }
    }

    // 4 — appearance.
    private var appearanceCard: some View {
        Card("appearance") {
            Picker("Theme", selection: Binding(get: { c.theme },
                                               set: { c.theme = $0 })) {
                ForEach(Theme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Note(c.theme.blurb)

            if !c.theme.bandIsFixed {
                Toggle("Coloured bar across the top",
                       isOn: Binding(get: { c.showsBand }, set: { c.showsBand = $0 }))
                    .font(.grooveSubhead)
                    .tint(.fairway)
            }
        }
    }

    // 5 — example data.
    private var sampleCard: some View {
        Card("example session") {
            Toggle("Show an example session", isOn: Binding(get: { c.isShowingExample },
                                                            set: { c.setExampleMode($0) }))
                .font(.grooveSubhead)
                .tint(.fairway)
            Note("Fills the app with a made-up session so you can see what your own will look like. It's on until you record a real one, and nothing made-up is ever saved.")
            if c.isShowingExample {
                Note("A marker sits at the top of every screen while it's on, so it can't be mistaken for your own swings.", tint: .accent)
            }
        }
    }

    // 6 — data out.
    private var dataCard: some View {
        Card("your data") {
            Row("swings saved", "\(c.realSwingCount)")
            if c.isShowingExample {
                Note("Export is off while the example is showing, so you can't send yourself a file of made-up swings.", tint: .accent)
            }
            if let url = c.exportURL() {
                ShareLink(item: url) {
                    Text("Export everything")
                        .font(.grooveSubhead)
                        .foregroundStyle(Color.cream)
                        .frame(maxWidth: .infinity).padding(Space.m + 2)
                        .background(Color.fairway,
                                    in: RoundedRectangle(cornerRadius: Radius.small))
                }
            }
            Note("A single file with every swing and its full motion trace, in case you want to look at it yourself.")
        }
    }

    // 7 — honest limits, in plain words.
    private var limitsCard: some View {
        Card("what this can't tell you") {
            Bullet("Nothing about the ball — no distance, no spin, no start line. It watches your body, not the shot.")
            Bullet("How hard you hit it is a rough guide, not a number to chase. On the longer clubs the watch reaches its limit, so a big hit and a huge one can read the same.")
            Bullet("It knows when you hit the ball to within about a hundredth of a second, which is plenty for timing but not for anything finer.")
        }
    }
}

/// Lets a card pick between two button styles without duplicating the label.
struct AnyButtonStyleBox: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Paired device
//
// The second screen. Read-only by design: it sits on a bag or a bench where it
// can be seen but not usefully tapped, so it mirrors state and offers no
// controls at all.

struct PairedDeviceView: View {
    @ObservedObject var c: PhoneController

    var body: some View {
        ZStack {
            Color.dusk.ignoresSafeArea()
            VStack(spacing: Space.xl) {
                header

                if c.isSessionLive || !c.summary.struckSwings.isEmpty {
                    HStack(spacing: Space.l) {
                        StatTile("swings", "\(c.summary.struckSwings.count)")
                        StatTile("repeatability",
                                 c.summary.struckSwings.count > 1
                                 ? String(format: "%.1f", c.summary.repeatability)
                                 : "—",
                                 unit: c.summary.struckSwings.count > 1 ? "%" : nil)
                        StatTile("tempo",
                                 c.summary.meanTempo > 0
                                 ? String(format: "%.2f", c.summary.meanTempo)
                                 : "—")
                    }
                    .padding(Space.l)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: Radius.card))

                    if c.summary.struckSwings.count > 1 {
                        ChartFrame(title: "every swing, stacked on impact",
                                   caption: "A tight band means you're repeating.",
                                   height: 260) {
                            EnsembleChart(traces: c.summary.struckSwings.map(\.normalizedTrace))
                        }
                    }
                } else {
                    EmptyState(icon: Icon.paired,
                               title: "Waiting for your phone",
                               message: "Start a session from your watch. This screen follows along.")
                }

                Spacer()
            }
            .padding(Space.xl)
            .frame(maxWidth: 900)
        }
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            Circle()
                .fill(c.isSessionLive ? Color.amber : Color.muted.opacity(0.4))
                .frame(width: 10, height: 10)
            Text(c.isSessionLive ? "Session running" : "Not running")
                .font(.grooveTitle).foregroundStyle(.bone)
            Spacer()
            Text("Second screen — nothing to tap here")
                .font(.grooveCaption).foregroundStyle(.muted)
        }
    }
}

// MARK: - Shared pieces

struct UndoToast: View {
    @ObservedObject var c: PhoneController
    let swing: Swing

    var body: some View {
        HStack {
            Text("Swing removed").font(.grooveCallout)
            Spacer()
            Button("Undo") { c.undoDelete() }
                .font(.grooveCallout.weight(.bold)).tint(.turf)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .background(Color.panel, in: Capsule())
        .overlay(Capsule().stroke(Color.muted.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, Space.xl).padding(.bottom, 60)
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
