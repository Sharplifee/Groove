import Foundation

// MARK: - The narrator
//
// Numbers first, but the app should also just SAY it. One or two plain
// sentences per session, built from the same measurements the tiles show —
// never a canned motivational line, never a claim the data doesn't back.
// Every sentence traces to a number, and if the data can't support a second
// sentence, there isn't one.

extension SessionSummary {

    /// One or two sentences about this session, in plain speech. The first
    /// states how the session went; the second — only when the data earns it —
    /// names the most useful specific thing in it.
    func narrative(previous: SessionSummary?) -> String {
        guard hasScore else {
            return "Not enough \(discipline.strokeWord)s yet to say anything honest about this session."
        }
        var sentences: [String] = [openingLine(previous: previous)]
        if let detail = detailLine(previous: previous) {
            sentences.append(detail)
        }
        return sentences.joined(separator: " ")
    }

    // The opener: the session in one clause, anchored on repeatability
    // because that's what the app is for.
    private func openingLine(previous: SessionSummary?) -> String {
        let word = discipline.strokeWord
        let base: String
        switch grooveScore ?? 0 {
        case 85...: base = "Tight session — your \(word)s were close to copies of each other."
        case 70...: base = "Good session. Most \(word)s repeated; a few drifted."
        case 55...: base = "A real pattern showed up, with room to tighten it."
        case 40...: base = "Loose day — your timing moved around between \(word)s."
        default:    base = "Scattered — no two \(word)s matched. Worth slowing everything down."
        }
        // If there's a previous comparable session and the change is real,
        // say the direction instead of only the level.
        if let prev = previous, prev.hasScore, hasScore {
            let delta = repeatability - prev.repeatability
            if delta <= -0.7 {
                return base + " Noticeably tighter than last time."
            }
            if delta >= 0.7 {
                return base + " Looser than last time, for what it's worth."
            }
        }
        return base
    }

    // The one specific, useful thing — picked by priority, not concatenated.
    private func detailLine(previous: SessionSummary?) -> String? {
        // 1. Within-session tempo drift: the classic bucket pattern where the
        //    swing quickens as the session goes on. Needs enough strokes to
        //    split into thirds honestly.
        let tempos = struckSwings.map(\.metrics.tempoRatio).filter { $0 > 0 }
        if tempos.count >= 9 {
            let third = tempos.count / 3
            let early = tempos.prefix(third).reduce(0, +) / Double(third)
            let late = tempos.suffix(third).reduce(0, +) / Double(third)
            let drift = (late - early) / early
            if drift < -0.08 {
                return "Your swing got quicker as the session went on — the last few \(discipline.strokeWord)s were noticeably faster than your first."
            }
            if drift > 0.08 {
                return "You slowed down as the session went on — the last few \(discipline.strokeWord)s took longer than your first."
            }
        }
        // 2. Sequencing, when it exists: the order of hips and hands is the
        //    most coachable single fact a full swing produces.
        if let lead = meanPelvisLead {
            if lead >= 20 {
                return "Your hips fired about \(Int(lead)) ms before your hands — that's the order you want."
            }
            if lead <= 0 {
                return "Your hands are starting down before your hips. Letting your lower body go first is the one thing worth working on from this session."
            }
        }
        // 3. Putting gets its own truth.
        if discipline == .putting, repeatability > 0 {
            return "On the green, repeating the stroke is the whole game — the read and the speed hide everything else."
        }
        return nil
    }
}
