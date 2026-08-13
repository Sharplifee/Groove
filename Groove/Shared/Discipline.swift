import Foundation

/// What you're standing over. Not a filter on one dataset — three genuinely
/// different problems that happen to share a sensor.
///
/// # Why this isn't just a tab
///
/// Everything the detector does is calibrated to a full swing, and none of those
/// numbers survive contact with a putting green.
///
/// A driver strike puts roughly 180 g through the wrist. A chip is a fraction of
/// that. A putt is a tap — under 10 g at the wrist, sometimes under 5 on a slow
/// green. Run the full-swing threshold over putting data and the impact crossing
/// simply never happens, which means no impact timestamp, which means no
/// alignment, which means the ensemble chart has nothing to stack on. Putts
/// don't read as bad swings in the old build; they don't exist.
///
/// The time windows are wrong too. A full swing runs about 1.2 s from takeaway
/// to contact; a putting stroke is nearer 0.6 s end to end. Capturing 1.2 s of
/// pre-roll on a putt means most of the trace is a player standing still, and
/// the interesting 200 ms gets squeezed into a sliver of the chart.
///
/// And the tempo reference moves. Tour full swings sit near 3:1 backswing to
/// downswing. Putting is closer to 2:1 — a putt accelerates through the ball
/// rather than releasing into it. Showing "tour average 3.00" beside a putting
/// stroke isn't a stretch, it's wrong.
///
/// # What carries over, and why putting is the best case for it
///
/// Repeatability, tempo consistency, and the impact-aligned ensemble apply to
/// all three, and they matter *most* on the green. A full swing has a ball
/// flight to tell you how it went. A putt that misses tells you almost nothing
/// about whether the stroke was sound — face angle, read and green speed all
/// confound the result. Stroke repeatability is one of the few things about
/// putting you can actually measure and improve directly, which makes this the
/// discipline where the app has the most to offer, not the least.
enum Discipline: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullSwing
    case chipping
    case putting

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullSwing: return "Full swing"
        case .chipping:  return "Chipping"
        case .putting:   return "Putting"
        }
    }

    /// Shown on the watch, where there's room for about two words.
    var shortLabel: String {
        switch self {
        case .fullSwing: return "Full"
        case .chipping:  return "Chip"
        case .putting:   return "Putt"
        }
    }

    var blurb: String {
        switch self {
        case .fullSwing:
            return "Driver through wedge, off a tee or the turf."
        case .chipping:
            return "Short shots around the green — pitches, chips, bump and runs."
        case .putting:
            return "On the green. This is where repeating the same stroke matters most."
        }
    }

    // MARK: Detection

    /// Peak jerk at the wrist that counts as contact.
    ///
    /// These scale with how much energy actually reaches the watch. The full
    /// swing number is measured; the other two are reasoned from strike energy
    /// and want a range session to confirm. They are deliberately generous —
    /// missing a putt entirely is far worse than occasionally counting a
    /// practice stroke, because a missed putt leaves no trace at all.
    var wristImpactThreshold: Double {
        switch self {
        case .fullSwing: return 180
        case .chipping:  return 45
        case .putting:   return 9
        }
    }

    /// Same crossing, felt through the body from a pocket. Chipping and putting
    /// barely register at the pelvis at all, which is why sequencing is not
    /// offered for them.
    var pelvisImpactThreshold: Double {
        switch self {
        case .fullSwing: return 35
        case .chipping:  return 12
        case .putting:   return 4
        }
    }

    /// Seconds of trace kept before contact. A putting stroke is roughly half
    /// the duration of a full swing, so keeping the full-swing window would fill
    /// most of the chart with a player standing still.
    var tracePre: TimeInterval {
        switch self {
        case .fullSwing: return 1.2
        case .chipping:  return 0.8
        case .putting:   return 0.55
        }
    }

    var tracePost: TimeInterval {
        switch self {
        case .fullSwing: return 0.4
        case .chipping:  return 0.3
        case .putting:   return 0.25
        }
    }

    /// What a good player's ratio tends to be, for the comparison on Form.
    var tempoReference: Double {
        switch self {
        case .fullSwing: return 3.0
        case .chipping:  return 2.5
        case .putting:   return 2.0
        }
    }

    var tempoReferenceLabel: String {
        switch self {
        case .fullSwing: return "tour average"
        case .chipping:  return "typical"
        case .putting:   return "typical"
        }
    }

    /// Whether dropping the music is worth doing.
    ///
    /// The whole point of the duck is to expose the strike. A driver has a crack
    /// worth hearing and a chip has a click that tells you where on the face you
    /// caught it. A putt has almost no sound, and ducking music forty times an
    /// hour on a practice green to reveal nothing would be pure irritation.
    /// Putting still records — it just doesn't touch your audio.
    var ducksAudio: Bool { self != .putting }

    /// Whether the pocket phone has anything useful to say. Hips barely move in
    /// a chip and effectively don't in a putt, so offering a sequencing number
    /// there would be measuring noise and presenting it as insight.
    var reportsSequencing: Bool { self == .fullSwing }

    /// How much of a real swing's motion range to expect. Used to scale the
    /// arming sensitivity so a putting stroke isn't judged against full-swing
    /// dynamics.
    var motionScale: Double {
        switch self {
        case .fullSwing: return 1.0
        case .chipping:  return 0.45
        case .putting:   return 0.15
        }
    }

    /// Practice swings are ubiquitous in the full swing, common in chipping, and
    /// nearly universal in putting — most players make one or two strokes beside
    /// the ball before every putt. The self-labelling loop needs to know how
    /// much of each to expect.
    var rehearsalsAreCommon: Bool { true }

    /// What a good number looks like here. Putting strokes are simpler motions,
    /// so the same player will repeat one far more tightly than a full swing —
    /// judging both against the full-swing bands would flatter putting and make
    /// the number meaningless.
    func repeatabilityVerdict(_ value: Double) -> String {
        guard value > 0 else { return "Not enough strokes yet." }
        let scale: Double = self == .putting ? 0.5 : (self == .chipping ? 0.75 : 1.0)
        switch value / scale {
        case ..<3.5: return "Very consistent — you're repeating the same \(strokeWord)."
        case ..<5:   return "Consistent. This is where you want to be."
        case ..<8:   return "A bit loose. Something is changing between \(strokeWord)s."
        default:     return "Every \(strokeWord) is different right now."
        }
    }

    var strokeWord: String {
        switch self {
        case .fullSwing: return "swing"
        case .chipping:  return "chip"
        case .putting:   return "stroke"
        }
    }

    /// Plural noun for counts: "26 swings", "26 putts".
    var countWord: String {
        switch self {
        case .fullSwing: return "swings"
        case .chipping:  return "chips"
        case .putting:   return "putts"
        }
    }
}
