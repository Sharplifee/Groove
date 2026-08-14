import Foundation

/// What you're standing over. Not a filter on one dataset — four genuinely
/// different problems that happen to share a sensor.
///
/// # The engine is calibrated for iron play, not for the driver
///
/// This matters more than it sounds. Detection thresholds are a floor: a swing
/// only registers if its impact transient crosses one. Set that floor by the
/// hardest shot in the bag and every gentler shot falls through it silently —
/// not recorded badly, not recorded at all.
///
/// A driver is the outlier, not the reference. It is the fastest club, and it
/// is the *only* full swing struck off a tee with a sweeping blow and no turf.
/// Calibrating to it puts the floor near the top of the range, where a full
/// pitching wedge — perhaps 55 to 65 percent of driver clubhead speed — sits
/// below the line and vanishes.
///
/// The right reference is the weakest full swing you would actually want
/// counted, which is a full wedge. Everything from there up to a 4-iron and
/// beyond clears it comfortably, driver included. A floor set by the quietest
/// member of a group costs nothing at the loud end; a floor set by the loudest
/// loses everyone else.
///
/// Two things also work in irons' favour and against the driver as a model.
/// An iron off turf takes a divot, and that turf interaction adds a sharp
/// second deceleration the teed driver simply doesn't have — so an iron's
/// transient has a distinct shape, not merely a smaller one. And ball
/// compression against a descending blow is sharper than the sweeping strike
/// that suits a driver. A detector tuned to a sweep is looking for the wrong
/// signature on the club you hit most.
///
/// # Why this isn't just a set of tabs
///
/// Every number below differs by discipline, and none of them survives being
/// borrowed from another.
///
/// A full iron puts on the order of 110 g of jerk through the wrist. A firm
/// chip is a fraction of that, a soft 58° pitch is a fraction again, and a putt
/// is a tap — under 10 g, sometimes under 5 on a slow green. Run one
/// discipline's threshold over another's data and the crossing never happens,
/// which means no impact timestamp, which means no alignment, which means the
/// ensemble chart has nothing to stack on.
///
/// The time windows differ too. A full swing runs about 1.1 s from takeaway to
/// contact; a putting stroke is nearer 0.6 s end to end. Keeping the full-swing
/// window on a putt fills most of the trace with a player standing still and
/// squeezes the interesting 200 ms into a sliver.
///
/// And the tempo reference moves. Full swings sit near 3:1 backswing to
/// downswing and hold there remarkably well across the bag. Finesse shots
/// shorten, and putting is nearer 2:1 — a putt accelerates through the ball
/// rather than releasing into it.
///
/// # Why putting and pitching are the best cases for this, not the worst
///
/// Repeatability, tempo consistency and the impact-aligned ensemble apply to
/// all four, and they matter *most* on and around the green. A full swing has a
/// ball flight to tell you how it went. A putt that misses tells you almost
/// nothing about whether the stroke was sound — face angle, read and green
/// speed all confound the result. A soft pitch that finishes ten feet past
/// might have been a perfect strike with the wrong club. Stroke repeatability
/// is one of the few things about the short game you can measure directly.
enum Discipline: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullSwing
    case chipping
    case pitching
    case putting

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullSwing: return "Full swing"
        case .chipping:  return "Chipping"
        case .pitching:  return "Pitching"
        case .putting:   return "Putting"
        }
    }

    /// Shown on the watch, where there's room for about two words.
    var shortLabel: String {
        switch self {
        case .fullSwing: return "Full"
        case .chipping:  return "Chip"
        case .pitching:  return "Pitch"
        case .putting:   return "Putt"
        }
    }

    var blurb: String {
        switch self {
        case .fullSwing:
            return "Pitching wedge through 4-iron and longer. Tuned for iron play — a full wedge is the quietest shot it has to catch, so everything above it is caught easily."
        case .chipping:
            return "Firmer shots from just off the green — bump and runs, low chips that release."
        case .pitching:
            return "58° wedge, ten to fifteen yards. Soft and precise, closer to a putt than to a swing."
        case .putting:
            return "On the green. This is where repeating the same stroke matters most."
        }
    }

    // MARK: Detection

    /// Peak jerk at the wrist that counts as contact.
    ///
    /// The full-swing number is set by a **full pitching wedge**, not a driver.
    /// A driver would put the floor near the top of the range and drop every
    /// shorter iron through it. Setting it at the quiet end costs nothing —
    /// a 4-iron or a driver clears 110 without difficulty — and it means the
    /// club you hit most is the club the engine is actually looking for.
    ///
    /// The short-game numbers step down with strike energy. They are
    /// deliberately generous, because missing a soft pitch entirely is far worse
    /// than occasionally counting a practice swing: a missed shot leaves no
    /// trace at all, while a stray rehearsal is one faint line on a chart.
    var wristImpactThreshold: Double {
        switch self {
        case .fullSwing: return 110   // full PW floor; long irons and driver clear easily
        case .chipping:  return 40    // firm chip, ball still compressed against turf
        case .pitching:  return 18    // 58° at 10-15 yds — finesse, barely more than a putt
        case .putting:   return 9
        }
    }

    /// Same crossing, felt through the body from a pocket. A full wedge turns
    /// the hips far less than a driver, so this steps down with the wrist
    /// figure. Below the full swing the hips barely participate at all, which is
    /// why sequencing isn't offered there.
    var pelvisImpactThreshold: Double {
        switch self {
        case .fullSwing: return 22
        case .chipping:  return 12
        case .pitching:  return 7
        case .putting:   return 4
        }
    }

    /// Seconds of trace kept before contact. An iron swing is marginally shorter
    /// than a driver swing, and the short game shorter again.
    var tracePre: TimeInterval {
        switch self {
        case .fullSwing: return 1.1
        case .chipping:  return 0.8
        case .pitching:  return 0.65
        case .putting:   return 0.55
        }
    }

    var tracePost: TimeInterval {
        switch self {
        case .fullSwing: return 0.4
        case .chipping:  return 0.3
        case .pitching:  return 0.28
        case .putting:   return 0.25
        }
    }

    /// What a good player's ratio tends to be, for the comparison on Form.
    /// Three to one holds remarkably well across the full-swing bag — it does
    /// not change between a wedge and a 4-iron — and shortens through the
    /// finesse shots.
    var tempoReference: Double {
        switch self {
        case .fullSwing: return 3.0
        case .chipping:  return 2.5
        case .pitching:  return 2.2
        case .putting:   return 2.0
        }
    }

    var tempoReferenceLabel: String {
        self == .fullSwing ? "tour average" : "typical"
    }

    /// Peak wrist rotation of a committed swing at this discipline — the
    /// intensity the impact floors were calibrated against. Feeds the
    /// intensity scaling so a warm-up half swing isn't judged on a
    /// full-commitment floor.
    var referenceRotation: Double { 22.0 * motionScale }

    /// Takeaway trigger, scaled to the discipline. The old fixed 1.4 rad/s was
    /// tuned on the full swing; a putting stroke or a soft pitch never crosses
    /// it and the motion goes entirely unseen. Floored above the stillness
    /// gate (0.35) so idle wrist noise can't start a swing.
    var takeawayThreshold: Double { max(0.45, 1.2 * motionScale) }

    /// Whether dropping the music is worth doing.
    ///
    /// The duck exists to expose the strike. An iron has a compression note that
    /// tells you instantly whether you caught it, and even a soft wedge has a
    /// click that separates a crisp strike from a thin or fat one — both worth
    /// hearing. A putt has almost nothing, and ducking music forty times an hour
    /// on a practice green to reveal silence would be pure irritation. Putting
    /// still records; it just leaves your audio alone.
    var ducksAudio: Bool { self != .putting }

    /// Whether the pocket phone has anything useful to say. Hips barely move in
    /// a chip, less in a pitch, and effectively not at all in a putt, so
    /// offering a sequencing number there would be measuring noise and
    /// presenting it as insight.
    var reportsSequencing: Bool { self == .fullSwing }

    /// Whether the watch's accelerometer can be pushed past its limit here. Only
    /// full swings get near it; nothing in the short game comes close, so the
    /// "peak is a floor, not a reading" caveat only applies to full swings.
    var canSaturateSensor: Bool { self == .fullSwing }

    /// How much of a full swing's motion range to expect. Used to scale arming
    /// sensitivity so a finesse wedge isn't judged against full-swing dynamics.
    var motionScale: Double {
        switch self {
        case .fullSwing: return 1.0
        case .chipping:  return 0.45
        case .pitching:  return 0.28
        case .putting:   return 0.15
        }
    }

    /// What a good number looks like here. Simpler motions repeat more tightly
    /// for the same player, so judging everything against the full-swing bands
    /// would flatter the short game into meaninglessness.
    var repeatabilityScale: Double {
        switch self {
        case .fullSwing: return 1.0
        case .chipping:  return 0.75
        case .pitching:  return 0.6
        case .putting:   return 0.5
        }
    }

    func repeatabilityVerdict(_ value: Double) -> String {
        guard value > 0 else { return "Not enough strokes yet." }
        switch value / repeatabilityScale {
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
        case .pitching:  return "pitch"
        case .putting:   return "stroke"
        }
    }

    /// Plural noun for counts: "26 swings", "26 putts".
    var countWord: String {
        switch self {
        case .fullSwing: return "swings"
        case .chipping:  return "chips"
        case .pitching:  return "pitches"
        case .putting:   return "putts"
        }
    }
}
