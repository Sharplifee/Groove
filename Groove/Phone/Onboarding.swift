import SwiftUI

/// First run. Three steps, in order: tell us about you, teach it your routine,
/// see the separation it found. Nothing touches your audio until this is done.
struct OnboardingView: View {
    @ObservedObject var c: PhoneController
    @State private var step = 0

    var body: some View {
        ZStack {
            Color.dusk.ignoresSafeArea()
            VStack(spacing: 0) {
                ProgressDots(count: 4, current: step).padding(.top, 20)

                TabView(selection: $step) {
                    welcome.tag(0)
                    about.tag(1)
                    access.tag(2)
                    calibrate.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    // MARK: 0 — what this is

    private var welcome: some View {
        Step(title: "Hear the strike.",
             message: "You keep listening to whatever you were listening to. When you start a real swing, the audio drops and your mic opens, so you hear the ball. A beat later it comes back.\n\nEvery swing gets logged while that happens.") {
            Button("Get started") { withAnimation { step = 1 } }
                .buttonStyle(Primary())
        }
    }

    // MARK: 1 — the two questions that can't be inferred

    private var about: some View {
        Step(title: "Two questions.",
             message: "Neither can be worked out from the sensors, and both change how your swing reads.") {
            VStack(spacing: 18) {
                Field("You play") {
                    Picker("", selection: $c.config.handedness) {
                        Text("Right-handed").tag(Handedness.right)
                        Text("Left-handed").tag(Handedness.left)
                    }.pickerStyle(.segmented)
                }
                Field("Watch on your") {
                    Picker("", selection: $c.config.watchWrist) {
                        Text("Left wrist").tag(Wrist.left)
                        Text("Right wrist").tag(Wrist.right)
                    }.pickerStyle(.segmented)
                }
                Field("Phone lives in") {
                    Picker("", selection: $c.config.pocket) {
                        Text("Back right").tag(Pocket.backRight)
                        Text("Back left").tag(Pocket.backLeft)
                        Text("Not on me").tag(Pocket.none)
                    }.pickerStyle(.segmented)
                }

                Text(c.config.watchIsLeadWrist
                     ? "That's your lead wrist — the one that controls the club face."
                     : "That's your trail wrist. It reads very differently through transition, which is exactly why we ask.")
                    .font(.footnote).foregroundStyle(.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if c.config.pocket == .none {
                    Text("Without the phone on you, we can't tell whether your hips lead your hands. Everything else still works.")
                        .font(.footnote).foregroundStyle(.alert)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Next") { withAnimation { step = 2 } }.buttonStyle(Primary())
            }
        }
    }

    // MARK: 2 — access
    //
    // Asked here rather than discovered mid-round. Every one of these failing
    // means the app silently does nothing instead of visibly breaking.

    private var access: some View {
        Step(title: "Two things to allow.",
             message: "Both are asked once. Without them a session looks like it's running and quietly isn't.") {
            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(title: "Microphone",
                              detail: "Opens for a second so you hear the ball. Nothing is recorded or kept.",
                              state: c.permissions.microphone,
                              onFix: { c.permissions.openSettings() })
                PermissionRow(title: "Motion",
                              detail: "Reads rotation from your pocket to tell whether your hips lead your hands.",
                              state: c.permissions.motion,
                              onFix: { c.permissions.openSettings() })

                Divider().overlay(Color.muted.opacity(0.3))

                Text("On your watch, allow Workouts when it asks. Without it the sensors stop the moment the screen sleeps.")
                    .font(.footnote).foregroundStyle(.muted)
                Text("While you're at the range this app keeps a silent audio session running. That's what stops iOS suspending it in your pocket — it won't interrupt what you're listening to.")
                    .font(.caption).foregroundStyle(.muted)

                Button(c.permissions.readyForBackground ? "Next" : "Allow access") {
                    if c.permissions.readyForBackground { withAnimation { step = 3 } }
                    else { Task { await c.permissions.requestAll() } }
                }
                .buttonStyle(Primary())

                if c.permissions.microphone == .denied {
                    Button("Continue without ducking") { withAnimation { step = 3 } }
                        .font(.footnote).tint(.muted)
                }
            }
            .task { c.permissions.refresh() }
        }
    }

    // MARK: 3 — teach it

    private var calibrate: some View {
        Step(title: "Teach it your routine.",
             message: "Go to the range and hit about ten balls the way you normally would, taking your usual rehearsals in between — including the deliberate ones when you're working on something. Those are the hard case.\n\nStart the session from your watch. Nothing will duck your audio during this pass.") {
            VStack(spacing: 16) {
                CalibrationProgress(real: c.summary.struckSwings.count,
                                    rehearsal: c.summary.rehearsals.count)

                if let result = c.calibrationResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.isReady ? "Ready" : "Not there yet")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(result.isReady ? Color.turf : Color.alert)
                        Text(result.verdict).font(.footnote).foregroundStyle(.muted)
                        SeparationBar(real: result.meanRealConfidence,
                                      rehearsal: result.meanRehearsalConfidence)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 15))
                }

                Button(c.calibrationResult?.isReady == true ? "Turn on ducking" : "Skip for now") {
                    c.finishCalibration(accepted: c.calibrationResult?.isReady == true)
                }
                .buttonStyle(Primary())

                Text("You can redo this any time from Setup.")
                    .font(.caption2).foregroundStyle(.muted)
            }
            .onAppear {
                // Stamp the window on arrival so only reps taken from here count.
                if c.config.calibrationStartedAt == nil { c.config.calibrationStartedAt = Date() }
            }
        }
    }
}

// MARK: - Pieces

private struct Step<Controls: View>: View {
    let title: String, message: String
    @ViewBuilder var controls: Controls

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.bone)
                Text(message).font(.callout).foregroundStyle(.muted)
                Spacer(minLength: 22)
                controls
            }
            .padding(24)
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9.5, design: .monospaced)).kerning(1.6)
                .foregroundStyle(.muted)
            content
        }
    }
}

struct ProgressDots: View {
    let count: Int, current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.turf : Color.muted.opacity(0.3))
                    .frame(width: i == current ? 20 : 6, height: 6)
                    .animation(.snappy, value: current)
            }
        }
    }
}

struct CalibrationProgress: View {
    let real: Int, rehearsal: Int
    private let target = 8

    var body: some View {
        HStack(spacing: 20) {
            counter("shots", real)
            counter("rehearsals", rehearsal)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 15))
    }

    private func counter(_ label: String, _ n: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(min(n, target)) / \(target)")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(n >= target ? Color.turf : Color.bone)
            Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shows the actual gap the detector found, rather than asking you to trust it.
struct SeparationBar: View {
    let real: Double, rehearsal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.muted.opacity(0.18))
                    Capsule().fill(Color.muted.opacity(0.5))
                        .frame(width: g.size.width * rehearsal, height: 6)
                        .offset(y: 5)
                    Capsule().fill(Color.turf)
                        .frame(width: g.size.width * real, height: 6)
                        .offset(y: -5)
                }
            }
            .frame(height: 24)
            HStack {
                Label("your shots", systemImage: "circle.fill")
                    .foregroundStyle(.turf)
                Spacer()
                Label("your rehearsals", systemImage: "circle.fill")
                    .foregroundStyle(.muted)
            }
            .font(.system(size: 9.5, design: .monospaced))
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
        }
    }
}
