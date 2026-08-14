import Foundation

// MARK: - The Groove Score
//
// One number for a session, 0–100, built only from things the app actually
// measures — and weighted the way the app's own coaching copy already talks.
// The doctrine everywhere else in this codebase is "your tempo being the same
// matters more than matching anyone else's", so the score does NOT grade tempo
// against the tour number. It grades what we preach:
//
//   Repeatability   55%   tempo variation stroke to stroke, discipline-fair
//   Smoothness      25%   normalised jerk, already 0–100 per swing
//   Sequencing      20%   hips-before-hands lead, full swing with a phone only
//
// When sequencing isn't available (short game, or no phone in the pocket) its
// weight folds back into the other two at the same 55:25 ratio, so a chipping
// session isn't silently docked twenty points for physics it doesn't have.
//
// Every component is a piecewise-linear map over explicit anchor points rather
// than a formula, because anchors can be read, argued with, and tested. The
// repeatability anchors are the same boundaries the verdict copy already uses
// (3.5 / 5 / 8 after discipline scaling), so the number and the words can
// never disagree.

enum GrooveScore {

    /// Linear interpolation over (input, output) anchors, clamped at the ends.
    static func piecewise(_ x: Double, _ anchors: [(Double, Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0  { return last.1 }
        for i in 1..<anchors.count where x <= anchors[i].0 {
            let (x0, y0) = anchors[i - 1], (x1, y1) = anchors[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return last.1
    }

    /// Repeatability % (already discipline-normalised by the caller) → 0–100.
    /// Anchors align with the verdict bands: "very consistent" territory lands
    /// in the high eighties, the 5% "where you want to be" line at 75, the 8%
    /// "a bit loose" boundary at 50.
    static func repeatability(_ normalised: Double) -> Double {
        piecewise(normalised, [(0, 100), (2, 94), (3.5, 87), (5, 75),
                               (8, 50), (12, 28), (18, 8), (24, 0)])
    }

    /// Pelvis lead in ms → 0–100. Positive means hips fired first. Zero — hips
    /// and hands together — is already a fault, so it sits well under half.
    static func sequencing(_ leadMs: Double) -> Double {
        piecewise(leadMs, [(-40, 0), (-15, 18), (0, 40), (12, 68),
                           (25, 86), (40, 96), (60, 100)])
    }
}

extension SessionSummary {

    /// Needs enough strokes for the variance maths to mean anything.
    var hasScore: Bool { struckSwings.count >= 3 && repeatability > 0 }

    /// 0–100 for how tightly the timing repeated, judged on this discipline's
    /// own scale — the same normalisation the verdict copy uses.
    var repeatabilityScore: Double? {
        guard hasScore else { return nil }
        return GrooveScore.repeatability(repeatability / discipline.repeatabilityScale)
    }

    /// Mean per-swing smoothness; each swing already carries 0–100.
    var smoothnessScore: Double? {
        let v = struckSwings.map(\.metrics.smoothness).filter { $0 > 0 }
        guard !v.isEmpty else { return nil }
        return min(100, max(0, v.reduce(0, +) / Double(v.count)))
    }

    /// 0–100 for hips leading hands. Only exists where sequencing is real.
    var sequencingScore: Double? {
        guard let lead = meanPelvisLead else { return nil }
        return GrooveScore.sequencing(lead)
    }

    /// The one number. Nil until three struck strokes exist.
    var grooveScore: Int? {
        guard let r = repeatabilityScore else { return nil }
        let s = smoothnessScore ?? r          // degenerate data: don't invent
        if let q = sequencingScore {
            return Int((0.55 * r + 0.25 * s + 0.20 * q).rounded())
        }
        // No sequencing available — 55:25 becomes 69:31 of the whole.
        return Int(((0.55 * r + 0.25 * s) / 0.80).rounded())
    }

    /// Broadcast-length verdicts. One or two words on screen; the sentence
    /// underneath does the explaining.
    var scoreVerdict: (title: String, detail: String)? {
        guard let g = grooveScore else { return nil }
        switch g {
        case 85...: return ("Dialed in", "Tight timing, clean speed. Keep whatever you're doing.")
        case 70...: return ("Grooved", "Repeating well. Small gains left in the loose \(discipline.strokeWord)s.")
        case 55...: return ("Solid", "A real pattern is there, with room to tighten it.")
        case 40...: return ("Loose", "Your timing is moving around between \(discipline.strokeWord)s.")
        default:    return ("Scattered", "No two \(discipline.strokeWord)s matched today. Slow it down.")
        }
    }
}
