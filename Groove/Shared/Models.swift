import Foundation

// MARK: - Configuration

enum Handedness: String, Codable, CaseIterable { case right, left }
enum Wrist: String, Codable, CaseIterable { case left, right }
enum Pocket: String, Codable, CaseIterable { case backRight, backLeft, none }

/// Named rather than numeric. "0.62" means nothing to a golfer.
enum Sensitivity: String, Codable, CaseIterable {
    case eager, balanced, strict

    var label: String {
        switch self {
        case .eager:    return "More often"
        case .balanced: return "Balanced"
        case .strict:   return "Only when sure"
        }
    }
    var detail: String {
        switch self {
        case .eager:    return "Catches every shot, but your music will sometimes dip during a practice swing."
        case .balanced: return "The usual choice. Rarely wrong either way."
        case .strict:   return "Never dips on a practice swing, but it'll miss the occasional shot."
        }
    }
    var threshold: Double {
        // PROVISIONAL. These were measured on the 367-record export, and that
        // export turned out to be pitching and chipping inside 15 yards with
        // the watch left in Full-swing mode (DECISIONS 43) — so the 73/62/49%
        // operating points describe a wedge routine, not a full-swing one.
        // They are kept because they are the only measured numbers that exist;
        // re-derive from a genuine full-swing diagnostic capture before
        // treating them as calibrated. The features cap near AUC 0.67 on that
        // data, so whatever the true numbers are, they are trade-offs, not
        // promises.
        switch self {
        case .eager: return 0.35
        case .balanced: return 0.45
        case .strict: return 0.55
        }
    }
}

/// When the music is allowed to drop.
///
/// The old design had exactly one mode — "only when the learned routine says
/// this is a real shot" — and it was gated behind a calibration pass that the
/// routine features (AUC ~0.67 on real data) rarely cleared. Anyone who tapped
/// "Skip for now" got an app whose headline feature never fired once. So the
/// default is now the honest one: every swing that starts from a settled
/// address ducks, and a practice swing simply costs a second of dipped audio
/// before the engine restores it. The routine-only mode is still here for a
/// player whose setup genuinely separates, and it is still gated on teaching.
enum DuckMode: String, Codable, CaseIterable {
    case everySwing, routineOnly, off

    var label: String {
        switch self {
        case .everySwing:  return "Every swing"
        case .routineOnly: return "Only real shots"
        case .off:         return "Never"
        }
    }
    var detail: String {
        switch self {
        case .everySwing:  return "Drops whenever you start a swing from address. A practice swing dips your music for about a second, then it comes back."
        case .routineOnly: return "Uses what it learned about your pre-shot routine to leave practice swings alone. Needs teaching first, and it will guess wrong sometimes."
        case .off:         return "Your music is never touched. Everything is still recorded."
        }
    }
}

struct Config: Codable, Equatable {
    var handedness: Handedness = .right
    var watchWrist: Wrist = .left
    var pocket: Pocket = .backRight

    /// Seconds to hold the duck after impact so the strike and turf aren't
    /// stepped on by the media coming back.
    var tailSeconds: TimeInterval = 0.8

    var sensitivity: Sensitivity = .balanced
    var armThreshold: Double { sensitivity.threshold }

    /// Optional so configs saved before this existed decode to the default.
    var duckModeStored: DuckMode?
    var duckMode: DuckMode {
        get { duckModeStored ?? .everySwing }
        set { duckModeStored = newValue }
    }

    /// Set once the player finishes first-run setup and calibration.
    var hasOnboarded = false
    var hasCalibrated = false
    /// Marks the start of the current calibration attempt, so re-teaching
    /// measures the new reps rather than the whole history.
    var calibrationStartedAt: Date?

    /// Don't duck until the session has seen its first real strike — you're
    /// warming up and there's nothing worth hearing yet.
    var gateUntilFirstImpact = true

    /// Is the watch on the lead (target-side) wrist?
    var watchIsLeadWrist: Bool {
        switch (handedness, watchWrist) {
        case (.right, .left), (.left, .right): return true
        default: return false
        }
    }

    static let storageKey = "groove.config"

    static func load() -> Config {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(d, forKey: Self.storageKey)
        }
    }
}

// MARK: - Motion

struct MotionFrame {
    let t: TimeInterval          // seconds since session start
    let accel: SIMD3<Double>     // user acceleration, g
    let rotation: SIMD3<Double>  // rad/s
    let gravity: SIMD3<Double>
    var accelMagnitude: Double { sqrt((accel * accel).sum()) }
    var rotationMagnitude: Double { sqrt((rotation * rotation).sum()) }
}

// MARK: - Setup routine

/// A stable-orientation hold inside the pre-swing window.
/// Deliberate setup produces several with sharp edges between them.
/// A loose rehearsal produces few, with soft edges.
struct Plateau: Codable, Equatable {
    let start: TimeInterval
    let duration: TimeInterval
    let orientationDelta: Double   // how far the wrist rotated to reach this hold
}

struct RoutineSignature: Codable, Equatable {
    var plateauCount: Int
    var meanDwell: TimeInterval
    var totalSetupDuration: TimeInterval
    var transitionSharpness: Double
    var dwellVariance: Double

    /// Feature vector, scaled so no single term dominates the distance.
    var vector: [Double] {
        [Double(plateauCount) / 5.0,
         meanDwell / 1.0,
         totalSetupDuration / 6.0,
         transitionSharpness / 0.5,
         dwellVariance / 0.5]
    }

    /// 0…1, where 1 is an exact match against a learned template.
    func similarity(to other: RoutineSignature) -> Double {
        let a = vector, b = other.vector
        let d = zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
        return max(0, 1 - d / 1.8)
    }
}

// MARK: - Swings

/// What a recorded motion actually was.
///
/// The engine used to know two things: a swing with a strike, and "everything
/// else that lasted three seconds". Walking to the next ball, raking one over,
/// teeing up and a waggle at address all landed in the second bucket as
/// "practice swings" — which is how three range sessions produced 275 of them
/// against 92 strikes, and why the self-training routine model learned that a
/// rehearsal looks like a stroll. Now a motion is only ever filed under a kind
/// it actually matches, and anything that isn't swing-shaped is counted and
/// dropped rather than logged as a rep.
enum SwingKind: String, Codable, CaseIterable {
    /// The club met the ball — an impact transient was found in the swing.
    case strike
    /// A full swing-shaped motion with no strike: a real practice swing.
    case practice
    /// A small aborted motion at address — club lifted, a waggle, a re-grip.
    /// Counted because Connor asked to see them, never scored.
    case waggle

    var label: String {
        switch self {
        case .strike:   return "real"
        case .practice: return "practice"
        case .waggle:   return "waggle"
        }
    }
}

/// How big the motion was relative to a committed swing at this discipline,
/// named the way a golfer would. Derived from peak wrist rotation against the
/// discipline's reference, so a half-speed warm-up seven and a full six read
/// differently on the card — one-handed and feel swings land in "easy".
enum SwingEffort: String, Codable, CaseIterable {
    case full, threeQuarter, half, easy

    var label: String {
        switch self {
        case .full:         return "full"
        case .threeQuarter: return "¾"
        case .half:         return "half"
        case .easy:         return "easy"
        }
    }

    /// `effort` is peak rotation / reference rotation, clamped later.
    static func from(effort: Double) -> SwingEffort {
        switch effort {
        case 0.82...: return .full
        case 0.62...: return .threeQuarter
        case 0.40...: return .half
        default:      return .easy
        }
    }
}

struct SwingMetrics: Codable, Equatable {
    /// What the player was doing. Defaults to `.fullSwing` so swings recorded
    /// before disciplines existed decode without loss.
    var discipline: Discipline = .fullSwing
    var backswing: TimeInterval = 0
    var downswing: TimeInterval = 0
    var transitionDwell: TimeInterval = 0
    var tempoRatio: Double = 0            // backswing / downswing, tour ≈ 3.0
    var transitionSharpness: Double = 0
    var smoothness: Double = 0            // 0…100, from normalized jerk
    var peakRotation: Double = 0          // rad/s at the wrist
    /// Milliseconds between the wrist's rotation peak and impact. This is the
    /// hands half of sequencing: the phone measures the same interval for the
    /// hips, and the difference is the lead. Optional so old records decode.
    var wristPeakLeadMs: Double?
    var clipped = false                   // sensor saturated — treat peaks as a floor
    /// Sharpest acceleration discontinuity in the swing window. Recorded for
    /// rehearsals too, precisely so an export can show whether "rehearsals"
    /// are hiding real strikes just under the floor. Optional so every record
    /// saved before this field existed still decodes.
    var peakJerk: Double?

    /// Populated only when a phone stream is present. Positive = the hips'
    /// rotation peak came before the hands' rotation peak, each measured
    /// against its own device's impact transient. Before 2026-09-01 this held
    /// hip-peak-to-impact alone, which is positive on every swing ever made.
    var pelvisLeadMs: Double?

    // MARK: Motion-level measurements (2026-10-27). All optional so every
    // record saved before they existed still decodes.

    /// Takeaway to the end of the follow-through, seconds.
    var duration: TimeInterval?
    /// Largest |user acceleration| the wrist saw, g.
    var peakAccel: Double?
    /// Peak rotation over the discipline's committed-swing reference, 0–1.2.
    var effort: Double?
    /// Whether the motion started from a settled address (≥ 0.6 s still).
    var startedFromAddress: Bool?
    /// 0–1: how strike-like the sharpest moment was. Above the strike line
    /// for a real swing; recorded for practice swings too so a borderline
    /// strike that was filed as practice can be seen in an export.
    var strikeScore: Double?
    /// Rotation integrated over the backswing, radians — a length proxy, so a
    /// half swing and a full swing separate on more than speed alone.
    var backswingSweep: Double?

    var effortLabel: SwingEffort? { effort.map(SwingEffort.from(effort:)) }
}

struct Swing: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    /// Groups swings into sessions so they don't pile into one flat list.
    var sessionID = UUID()
    /// Real swings self-label: a struck ball produces an impact transient,
    /// a rehearsal does not. No manual tagging required, ever.
    var struck: Bool
    /// Optional for decoding; `resolvedKind` is what the app reads.
    var kind: SwingKind?
    var routine: RoutineSignature
    var armConfidence: Double
    var metrics: SwingMetrics
    /// Impact-aligned, time-normalized |acceleration| trace for the ensemble.
    /// Practice swings carry one too, aligned on their own speed peak, so a
    /// practice swing and a real one can be laid over each other.
    var normalizedTrace: [Double]

    init(id: UUID = UUID(), date: Date = Date(), sessionID: UUID = UUID(),
         struck: Bool, kind: SwingKind? = nil, routine: RoutineSignature,
         armConfidence: Double, metrics: SwingMetrics, normalizedTrace: [Double]) {
        self.id = id; self.date = date; self.sessionID = sessionID
        self.struck = struck
        self.kind = kind ?? (struck ? .strike : .practice)
        self.routine = routine; self.armConfidence = armConfidence
        self.metrics = metrics; self.normalizedTrace = normalizedTrace
    }

    /// Records saved before `kind` existed are either strikes or practice.
    var resolvedKind: SwingKind { kind ?? (struck ? .strike : .practice) }
}

struct SessionSummary {
    var swings: [Swing]

    var struckSwings: [Swing] { swings.filter(\.struck) }
    /// Practice swings only — waggles are not rehearsals of anything.
    var rehearsals: [Swing] { swings.filter { $0.resolvedKind == .practice } }
    var waggles: [Swing] { swings.filter { $0.resolvedKind == .waggle } }

    var meanTempo: Double {
        let v = struckSwings.map(\.metrics.tempoRatio).filter { $0 > 0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    /// Tempo of the practice swings, measured against their own speed peak
    /// where a ball would have been. A player whose practice swings run 3.2
    /// and whose real ones run 2.6 is quickening over the ball, and that is
    /// one of the most useful things this app can say.
    var meanPracticeTempo: Double {
        let v = rehearsals.map(\.metrics.tempoRatio).filter { $0 > 0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    /// Real-swing tempo minus practice-swing tempo. Negative = quicker over
    /// the ball than in rehearsal. Nil until both sides have three reps.
    var tempoShiftOverBall: Double? {
        let r = struckSwings.map(\.metrics.tempoRatio).filter { $0 > 0 }
        let p = rehearsals.map(\.metrics.tempoRatio).filter { $0 > 0 }
        guard r.count >= 3, p.count >= 3 else { return nil }
        return r.reduce(0, +) / Double(r.count) - p.reduce(0, +) / Double(p.count)
    }

    /// How many real swings landed in each effort band, biggest first.
    var effortMix: [(SwingEffort, Int)] {
        let counts = Dictionary(grouping: struckSwings.compactMap(\.metrics.effortLabel), by: { $0 })
            .mapValues(\.count)
        return SwingEffort.allCases.compactMap { e in counts[e].map { (e, $0) } }
    }

    /// ONE canonical consistency number for the whole app.
    ///
    /// Vocabulary rule: this is always called **Repeatability**, always shown as
    /// a percentage, and always lower-is-better. Never "variation", never
    /// "tempo CV", never "band width" in user-facing copy.
    var repeatability: Double {
        let v = struckSwings.map(\.metrics.tempoRatio).filter { $0 > 0 }
        guard v.count > 1 else { return 0 }
        let m = v.reduce(0, +) / Double(v.count)
        let sd = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
        return m == 0 ? 0 : sd / m * 100
    }

    /// The discipline these swings belong to. A session is normally one
    /// discipline; if it somehow mixes, the most common one wins so the
    /// thresholds and wording stay coherent.
    var discipline: Discipline {
        // Every motion votes, not only strikes: a putting session whose
        // strokes all fell under the floor must still be a putting session,
        // or it gets the full swing's words and bands.
        let all = swings.map(\.metrics.discipline)
        guard !all.isEmpty else { return .fullSwing }
        return Dictionary(grouping: all, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })!.key
    }

    /// Judged against the discipline's own bands. A putting stroke is a simpler
    /// motion than a full swing, so the same player repeats it far more tightly
    /// — scoring both on the full-swing scale would flatter putting into
    /// meaninglessness.
    var repeatabilityVerdict: String {
        discipline.repeatabilityVerdict(repeatability)
    }

    /// Only the swings from one discipline, for a Form tab filtered to it.
    func filtered(to d: Discipline) -> SessionSummary {
        SessionSummary(swings: swings.filter { $0.metrics.discipline == d })
    }

    /// Which disciplines actually appear here, in a stable order.
    var disciplinesPresent: [Discipline] {
        Discipline.allCases.filter { d in
            swings.contains { $0.metrics.discipline == d }
        }
    }

    /// Average milliseconds by which the hips led the hands, across the swings
    /// that carried a phone. Nil when the phone wasn't in a pocket.
    var meanPelvisLead: Double? {
        // Hips barely move in a chip and effectively don't in a putt. Reporting
        // a number there would be measuring noise and presenting it as insight.
        guard discipline.reportsSequencing else { return nil }
        let v = struckSwings.compactMap(\.metrics.pelvisLeadMs)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }
}

// MARK: - Sessions

/// Swings grouped by the range session they came from, newest first.
struct RangeSession: Identifiable {
    let id: UUID
    let date: Date
    let swings: [Swing]

    var summary: SessionSummary { SessionSummary(swings: swings) }
    var struckCount: Int { swings.filter(\.struck).count }

    static func group(_ swings: [Swing]) -> [RangeSession] {
        Dictionary(grouping: swings, by: \.sessionID)
            .map { id, group in
                RangeSession(id: id,
                             date: group.map(\.date).min() ?? Date(),
                             swings: group.sorted { $0.date > $1.date })
            }
            .sorted { $0.date > $1.date }
    }
}

// MARK: - Calibration

/// First-run teaching pass. The player takes a handful of real shots and a
/// handful of rehearsals, and we show the separation we found before the
/// detector is ever trusted to touch their audio.
struct CalibrationResult {
    var realCount: Int
    var rehearsalCount: Int
    var meanRealConfidence: Double
    var meanRehearsalConfidence: Double

    var separation: Double { meanRealConfidence - meanRehearsalConfidence }
    var isReady: Bool { realCount >= 8 && rehearsalCount >= 8 && separation > 0.18 }

    var verdict: String {
        if realCount < 8 || rehearsalCount < 8 { return "Keep going — a few more of each." }
        switch separation {
        case ..<0.10: return "Your practice swings look almost exactly like your real ones, so it will guess sometimes. Try \"Only when sure\"."
        case ..<0.18: return "Close, but workable. Start on \"Only when sure\" and loosen it once you trust it."
        default:      return "It can tell your real swings from your practice ones clearly."
        }
    }
}
