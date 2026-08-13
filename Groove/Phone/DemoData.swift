import Foundation

/// A worked example session — realistic enough that a new player can see
/// exactly what their own numbers will look like before hitting a ball.
///
/// This is what a fresh install shows. It is not a debugging aid hidden behind
/// a toggle; opening the app to three empty screens was the complaint, and the
/// answer is that the app is never empty.
///
/// Nothing here is persisted and nothing reaches `SwingStore`. Example swings
/// live only in memory, so they can't contaminate a real baseline or the
/// self-training template.
enum DemoData {

    /// Acceleration trace shaped like an actual golf swing: quiet setup, a ramp
    /// through the backswing, a dip at transition, the downswing surge, the
    /// impact spike, then decay through the follow-through.
    ///
    /// `looseness` widens the per-swing variation — 0 is a machine, 1 is a bad day.
    static func trace(seed: Int, looseness: Double = 0.35) -> [Double] {
        let n = SwingAnalyzer.traceLength
        let impactAt = SwingAnalyzer.tracePre
            / (SwingAnalyzer.tracePre + SwingAnalyzer.tracePost)

        func rand(_ salt: Int) -> Double {
            let x = sin(Double(seed) * 97.13 + Double(salt) * 3.7) * 43758.5453
            return x - x.rounded(.down)
        }
        let tempo = 1 + (rand(1) - 0.5) * 0.16 * looseness
        let gain  = 1 + (rand(2) - 0.5) * 0.30 * looseness
        let wobble = (rand(3) - 0.5) * 0.05 * looseness

        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            var v = 0.05 + 0.03 * sin(t * 22 + Double(seed))
            if t > 0.10 {
                let u = (t - 0.10) / (impactAt - 0.10)
                v += 0.55 * pow(max(0, u), 1.6) * tempo
                v -= 0.30 * exp(-pow((u - 0.52 + wobble) / 0.10, 2))
                v += 2.90 * exp(-pow((u - 0.985) / 0.055, 2)) * gain
            }
            if t > impactAt {
                let d = t - impactAt
                v += 3.60 * exp(-d * 46) * gain
                v += 0.50 * exp(-d * 9) * sin(d * 90)
            }
            return max(0, v)
        }
    }

    static func swing(seed: Int,
                      sessionID: UUID,
                      date: Date,
                      struck: Bool = true,
                      looseness: Double = 0.35,
                      hasPelvis: Bool = true,
                      discipline: Discipline = .fullSwing) -> Swing {
        func rand(_ salt: Int) -> Double {
            let x = sin(Double(seed) * 41.7 + Double(salt) * 11.3) * 24634.6345
            return x - x.rounded(.down)
        }

        guard struck else {
            // A rehearsal: no strike, no trace, low routine confidence.
            return Swing(date: date, sessionID: sessionID, struck: false,
                         routine: RoutineSignature(plateauCount: 1,
                                                   meanDwell: 0.22,
                                                   totalSetupDuration: 0.9,
                                                   transitionSharpness: 0.08,
                                                   dwellVariance: 0.05),
                         armConfidence: 0.18 + rand(9) * 0.16,
                         metrics: { var m = SwingMetrics(); m.discipline = discipline; return m }(),
                         normalizedTrace: [])
        }

        // Stroke duration and ratio both move with the discipline. A putting
        // stroke is roughly half the length of a full swing and accelerates
        // through the ball rather than releasing into it, so it sits nearer
        // 2:1 than 3:1. Generating everything at full-swing timings would make
        // the putting tab show a player with a driver's tempo on the green.
        let span: Double = { switch discipline {
            case .fullSwing: return 1.0
            case .chipping:  return 0.72
            case .putting:   return 0.5 } }()
        let ratio = discipline.tempoReference
        let down = 0.26 * span + (rand(2) - 0.5) * 0.04 * looseness
        let back = down * ratio + (rand(1) - 0.5) * 0.10 * looseness
        var m = SwingMetrics()
        m.discipline = discipline
        m.backswing = back
        m.downswing = down
        m.tempoRatio = back / down
        m.transitionDwell = 0.18 + (rand(3) - 0.5) * 0.08 * looseness
        m.transitionSharpness = 22 + rand(4) * 8
        m.smoothness = 84 + rand(5) * 12 - looseness * 10
        m.peakRotation = 24 + rand(6) * 6
        // Only a full swing hits hard enough to saturate the watch, and only a
        // full swing turns the hips enough for the pocket phone to read.
        m.clipped = discipline == .fullSwing && rand(7) > 0.72
        if hasPelvis && discipline.reportsSequencing {
            m.pelvisLeadMs = 28 + (rand(8) - 0.35) * 70
        }

        return Swing(date: date, sessionID: sessionID, struck: true,
                     routine: RoutineSignature(plateauCount: 3,
                                               meanDwell: 0.72 + rand(10) * 0.2,
                                               totalSetupDuration: 3.4,
                                               transitionSharpness: 0.31,
                                               dwellVariance: 0.11),
                     armConfidence: 0.72 + rand(11) * 0.22,
                     metrics: m,
                     normalizedTrace: trace(seed: seed, looseness: looseness))
    }

    /// A full history: several sessions, each with struck swings and the
    /// rehearsals between them, loosening slightly as fatigue sets in.
    ///
    /// `improvement` tilts the whole history so older sessions are looser than
    /// recent ones. At 0 the sessions differ only by noise, which is right for
    /// a preview but wrong for the first-run example — a trend card showing
    /// random scatter teaches a new player nothing and reads as broken. The
    /// example passes a real value so the line has the direction the card
    /// promises.
    static func history(sessions: Int = 3, perSession: Int = 34,
                        improvement: Double = 0,
                        discipline: Discipline = .fullSwing) -> [Swing] {
        var out: [Swing] = []
        var seed = 1
        for s in 0..<sessions {
            let id = UUID()
            let day = Calendar.current.date(byAdding: .day, value: -s * 4, to: Date())!
            // Offset the hour per discipline so a chipping session and a full
            // swing session on the same afternoon stay separate sessions rather
            // than merging into one mixed block.
            let hour = 17 - Discipline.allCases.firstIndex(of: discipline)!
            let start = Calendar.current.date(bySettingHour: hour, minute: 20, second: 0, of: day)!
            // s == 0 is the most recent session, so age scales the older ones up.
            let age = sessions > 1 ? Double(s) / Double(sessions - 1) : 0
            // A dead-straight improvement curve looks fabricated — nobody gets
            // measurably better every single session. One session bucks the
            // trend, which is what a real run of form looks like. The endpoints
            // are left alone so the overall direction still reads clearly.
            let offDay = (s == 1 && sessions > 2) ? 1.7 : 1.0
            let era = (1 + improvement * age) * offDay
            for i in 0..<perSession {
                // Repeatability degrades through a session — that's the fatigue
                // drift the Form tab is meant to reveal.
                // Putting strokes are simpler motions and repeat far more
                // tightly than full swings, so the spread has to scale or the
                // example would show a player who putts like a machine.
                let fatigue = (0.28 + Double(i) / Double(perSession) * 0.42)
                    * era * discipline.motionScale
                let at = start.addingTimeInterval(Double(i) * 46)
                out.append(swing(seed: seed, sessionID: id, date: at,
                                 looseness: fatigue, discipline: discipline))
                seed += 1
                // One or two rehearsals between shots, as in life.
                for r in 0..<(i % 3 == 0 ? 2 : 1) {
                    out.append(swing(seed: seed, sessionID: id,
                                     date: at.addingTimeInterval(Double(r) * 6 - 20),
                                     struck: false, discipline: discipline))
                    seed += 1
                }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    /// A single tidy session, for previewing.
    static let oneSession: [Swing] = history(sessions: 1, perSession: 18)

    /// What a fresh install shows: enough history for the trend line and the
    /// ensemble overlay to both have something to say, and a believable arc of
    /// improvement so the trend card reads as a story rather than as noise.
    /// A fresh install opens on all three disciplines populated, so the Form
    /// tab's practice picker has something behind every option. Someone who has
    /// never opened the app should be able to see what its putting analysis
    /// looks like before deciding whether to walk to the green with it.
    static func exampleSwings() -> [Swing] {
        history(sessions: 4, perSession: 26, improvement: 1.5, discipline: .fullSwing)
        + history(sessions: 2, perSession: 18, improvement: 0.8, discipline: .chipping)
        + history(sessions: 2, perSession: 22, improvement: 1.0, discipline: .putting)
    }
}
