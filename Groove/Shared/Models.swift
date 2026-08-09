import Foundation

// MARK: - Configuration

enum Handedness: String, Codable, CaseIterable { case right, left }
enum Wrist: String, Codable, CaseIterable { case left, right }
enum Pocket: String, Codable, CaseIterable { case backRight, backLeft, none }

enum AudioRoute: String, Codable, CaseIterable {
    case earbuds        // default — any brand, HFP / wired / USB-C
    case phoneMic
    case pairedDevice   // companion app on iPad / Mac / 2nd iPhone
}

/// Named rather than numeric. "0.62" means nothing to a golfer.
enum Sensitivity: String, Codable, CaseIterable {
    case eager, balanced, strict

    var label: String {
        switch self {
        case .eager:    return "Ducks more often"
        case .balanced: return "Balanced"
        case .strict:   return "Only when certain"
        }
    }
    var detail: String {
        switch self {
        case .eager:    return "Catches every shot. Occasionally dips during a rehearsal."
        case .balanced: return "The default. Rarely wrong either way."
        case .strict:   return "Never dips on a rehearsal. Will miss the odd shot."
        }
    }
    var threshold: Double {
        switch self {
        case .eager: return 0.45
        case .balanced: return 0.62
        case .strict: return 0.78
        }
    }
}

struct Config: Codable, Equatable {
    var handedness: Handedness = .right
    var watchWrist: Wrist = .left
    var pocket: Pocket = .backRight
    var route: AudioRoute = .earbuds

    /// Seconds to hold the duck after impact so the strike and turf aren't
    /// stepped on by the media coming back.
    var tailSeconds: TimeInterval = 0.8

    var sensitivity: Sensitivity = .balanced
    var armThreshold: Double { sensitivity.threshold }

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

struct SwingMetrics: Codable, Equatable {
    var backswing: TimeInterval = 0
    var downswing: TimeInterval = 0
    var transitionDwell: TimeInterval = 0
    var tempoRatio: Double = 0            // backswing / downswing, tour ≈ 3.0
    var transitionSharpness: Double = 0
    var smoothness: Double = 0            // 0…100, from normalized jerk
    var peakRotation: Double = 0          // rad/s at the wrist
    var clipped = false                   // sensor saturated — treat peaks as a floor

    /// Populated only when a phone stream is present.
    var pelvisLeadMs: Double?             // positive = hips peaked before hands
}

struct Swing: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    /// Groups swings into sessions so they don't pile into one flat list.
    var sessionID = UUID()
    /// Real swings self-label: a struck ball produces an impact transient,
    /// a rehearsal does not. No manual tagging required, ever.
    var struck: Bool
    var routine: RoutineSignature
    var armConfidence: Double
    var metrics: SwingMetrics
    /// Impact-aligned, time-normalized |acceleration| trace for the ensemble.
    var normalizedTrace: [Double]
}

struct SessionSummary {
    var swings: [Swing]

    var struckSwings: [Swing] { swings.filter(\.struck) }
    var rehearsals: [Swing] { swings.filter { !$0.struck } }

    var meanTempo: Double {
        let v = struckSwings.map(\.metrics.tempoRatio).filter { $0 > 0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
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

    var repeatabilityVerdict: String {
        switch repeatability {
        case 0:        return "Not enough swings yet."
        case ..<3.5:   return "Very tight — you're repeating."
        case ..<5:     return "Tight. This is the range you want."
        case ..<8:     return "Loose. Something's moving between swings."
        default:       return "Not repeating yet."
        }
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
        if realCount < 8 || rehearsalCount < 8 { return "Keep going." }
        switch separation {
        case ..<0.10: return "Your rehearsals look almost identical to your shots. The detector will guess. Try Only when certain, or use the watch to arm it yourself."
        case ..<0.18: return "Workable but close. Start on Only when certain and loosen it later."
        default:      return "Clean separation. Your routine is distinctive enough to trust."
        }
    }
}
