import SwiftUI

/// First run. Four steps: what it does, three questions about you, what it needs
/// permission for, and teaching it your swing. Nothing touches your audio until
/// this is done.
struct OnboardingView: View {
    @ObservedObject var c: PhoneController
    @State private var step = 0

    var body: some View {
        ZStack {
            Color.dusk.ignoresSafeArea()
            VStack(spacing: 0) {
                ProgressDots(count: 4, current: step).padding(.top, Space.xl)

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
        Step(title: "Hear every strike.",
             message: "Keep listening to whatever you were listening to. The moment you start a real swing, your music drops so you hear the ball come off the face — then it comes straight back.\n\nEvery swing gets recorded while that happens, so you can see which ones repeated and which didn't.") {
            Button("Get started") { withAnimation(Motion.transition) { step = 1 } }
                .buttonStyle(PrimaryButton())
        }
    }

    // MARK: 1 — the three things that can't be worked out from the sensors

    private var about: some View {
        Step(title: "Three quick questions.",
             message: "None of these can be worked out from the sensors, and each one changes how your swing reads.") {
            VStack(spacing: Space.xl) {
                Question(title: "Which hand do you play?",
                         selection: $c.config.handedness) {
                    Text("Right-handed").tag(Handedness.right)
                    Text("Left-handed").tag(Handedness.left)
                }

                Question(title: "Which wrist is your watch on?",
                         help: c.config.watchIsLeadWrist
                            ? "That's your front wrist — the one nearer the target."
                            : "That's your back wrist. It moves differently through the swing, which is why it's worth knowing.",
                         selection: $c.config.watchWrist) {
                    Text("Left wrist").tag(Wrist.left)
                    Text("Right wrist").tag(Wrist.right)
                }

                Question(title: "Which pocket holds your phone?",
                         help: c.config.pocket == .none
                            ? "Without the phone on you it still works — you just won't see whether your hips lead your hands."
                            : "From your pocket, the phone can feel your hips turn.",
                         selection: $c.config.pocket) {
                    Text("Back right").tag(Pocket.backRight)
                    Text("Back left").tag(Pocket.backLeft)
                    Text("Not on me").tag(Pocket.none)
                }

                Button("Next") { withAnimation(Motion.transition) { step = 2 } }
                    .buttonStyle(PrimaryButton())
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
            VStack(alignment: .leading, spacing: Space.l) {
                PermissionRow(title: "Microphone",
                              detail: "Listens for the moment you hit the ball so it can play that sound back to you. Nothing is recorded or kept.",
                              state: c.permissions.microphone,
                              onFix: { c.permissions.openSettings() })
                PermissionRow(title: "Motion",
                              detail: "Feels your hips turn from your pocket, so it can tell you whether they lead your hands.",
                              state: c.permissions.motion,
                              onFix: { c.permissions.openSettings() })

                Divider().overlay(Color.muted.opacity(0.3))

                Note("On your watch, allow Workouts when it asks. Without it the sensors stop the moment the screen sleeps.")
                Note("You can put your phone in your pocket and forget about it — it keeps working with the screen off. It only stops if you swipe it away in the app switcher.")

                Button(c.permissions.readyForBackground ? "Next" : "Allow access") {
                    if c.permissions.readyForBackground {
                        withAnimation(Motion.transition) { step = 3 }
                    } else {
                        Task { await c.permissions.requestAll() }
                    }
                }
                .buttonStyle(PrimaryButton())

                if c.permissions.microphone == .denied {
                    Button("Continue without the strike sound") {
                        withAnimation(Motion.transition) { step = 3 }
                    }
                    .buttonStyle(SecondaryButton())
                }
            }
            .task { c.permissions.refresh() }
        }
    }

    // MARK: 3 — teach it

    private var calibrate: some View {
        Step(title: "Teach it your swing.",
             message: "Go hit about ten balls the way you normally would, taking your usual practice swings in between — including the serious ones when you're working on something. Those are the hard ones for it to tell apart.\n\nStart the session from your watch. Your music won't drop during this part.") {
            VStack(spacing: Space.l) {
                CalibrationProgress(real: c.summary.struckSwings.count,
                                    rehearsal: c.summary.rehearsals.count)

                if let result = c.calibrationResult {
                    Card(nil) {
                        Text(result.isReady ? "Ready" : "Not there yet")
                            .font(.grooveSubhead)
                            .foregroundStyle(result.isReady ? Color.turf : Color.alert)
                        Note(result.verdict)
                        SeparationBar(real: result.meanRealConfidence,
                                      rehearsal: result.meanRehearsalConfidence)
                    }
                }

                Button(c.calibrationResult?.isReady == true
                       ? "Turn it on" : "Skip for now") {
                    c.finishCalibration(accepted: c.calibrationResult?.isReady == true)
                }
                .buttonStyle(PrimaryButton())

                Note("You can redo this any time from Setup.")
            }
            .onAppear {
                // Stamp the window on arrival so only reps taken from here count.
                if c.config.calibrationStartedAt == nil {
                    c.config.calibrationStartedAt = Date()
                }
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
            VStack(alignment: .leading, spacing: Space.l) {
                Text(title)
                    .font(.grooveTitle)
                    .foregroundStyle(.bone)
                Text(message)
                    .font(.grooveBody).foregroundStyle(.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.xl)
                controls
            }
            .padding(Space.xl)
        }
    }
}

struct ProgressDots: View {
    let count: Int, current: Int
    var body: some View {
        HStack(spacing: Space.s - 2) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.turf : Color.muted.opacity(0.3))
                    .frame(width: i == current ? 20 : 6, height: 6)
                    .animation(Motion.value, value: current)
            }
        }
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

struct CalibrationProgress: View {
    let real: Int, rehearsal: Int
    private let target = 8

    var body: some View {
        HStack(spacing: Space.xl) {
            counter("real shots", real)
            counter("practice swings", rehearsal)
        }
        .frame(maxWidth: .infinity)
        .padding(Space.l)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func counter(_ label: String, _ n: Int) -> some View {
        VStack(spacing: Space.xs) {
            Text("\(min(n, target)) / \(target)")
                .font(.grooveFigure)
                .foregroundStyle(n >= target ? Color.turf : Color.bone)
            Text(label).font(.grooveCaption).foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Shows the actual gap it found between your real swings and your practice
/// ones, rather than asking you to take its word for it.
struct SeparationBar: View {
    let real: Double, rehearsal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 1) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.muted.opacity(0.18))
                    Capsule().fill(Color.accent)
                        .frame(width: g.size.width * rehearsal, height: 6)
                        .offset(y: 5)
                    Capsule().fill(Color.turf)
                        .frame(width: g.size.width * real, height: 6)
                        .offset(y: -5)
                }
            }
            .frame(height: 24)
            HStack {
                Label("your real swings", systemImage: "circle.fill")
                    .foregroundStyle(.turf)
                Spacer()
                Label("your practice swings", systemImage: "circle.fill")
                    .foregroundStyle(.accent)
            }
            .font(.grooveEyebrow)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
        }
        .accessibilityLabel("The gap between your real swings and your practice swings")
    }
}
