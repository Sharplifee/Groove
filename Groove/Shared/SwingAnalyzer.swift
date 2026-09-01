import Foundation

/// All the signal processing, kept free of CoreMotion and UIKit so it can be
/// unit-tested against recorded CSVs on any platform.
enum SwingAnalyzer {

    static let fs: Double = 100                 // Hz

    /// Jerk thresholds are sensor-position specific. A wrist takes the full
    /// shock of the strike; a phone in a back pocket sees a fraction of it
    /// through the body. Using the wrist number on pelvis data means the
    /// crossing never happens and the metric silently returns nil forever.
    /// Full-swing defaults, calibrated to a **full pitching wedge** rather than
    /// a driver. A driver sets the floor near the top of the range and drops
    /// every shorter iron through it; a wedge floor costs nothing at the loud
    /// end, since a 4-iron or a driver clears it easily.
    ///
    /// Each discipline overrides these. A putt puts under a tenth of a full
    /// iron's energy through the wrist, so this threshold would never be
    /// crossed on a green and the stroke would leave no trace at all. See
    /// `Discipline`.
    static let wristImpactThreshold: Double = 110
    static let pelvisImpactThreshold: Double = 22
    static let traceLength = 240                // resampled ensemble length
    static let tracePre: TimeInterval = 1.1     // seconds before impact
    static let tracePost: TimeInterval = 0.4

    // MARK: - Setup segmentation

    /// Splits the pre-swing window into stable-orientation holds.
    ///
    /// The discriminator between a real setup and a rehearsal is not one pause —
    /// it's the *sequence*: deliberate means several distinct plateaus with sharp
    /// edges; loose means continuous drift with soft or absent edges.
    static func plateaus(_ frames: [MotionFrame],
                         minDwell: TimeInterval = 0.15,
                         window: Int = 15) -> [Plateau] {
        guard frames.count > window * 2 else { return [] }

        // Rolling spread of the gravity vector: "am I holding still?"
        var deviation = [Double](repeating: 0, count: frames.count)
        for i in 0..<frames.count {
            let lo = max(0, i - window), hi = min(frames.count - 1, i + window)
            let slice = frames[lo...hi].map(\.gravity)
            let mean = slice.reduce(SIMD3<Double>.zero, +) / Double(slice.count)
            let varSum = slice.map { d -> Double in
                let e = d - mean; return (e * e).sum()
            }.reduce(0, +) / Double(slice.count)
            deviation[i] = varSum.squareRoot()
        }

        // A purely relative threshold gave every window plateaus: a wrist that
        // never stops still has a quietest quartile, so a fidgeting rehearsal
        // produced holds with dwells and edges just like a deliberate setup,
        // and the feature set threw away the absolute stillness that actually
        // separates the two. Relative refinement, absolute ceiling: a "hold"
        // has to be genuinely still, not merely stiller than the rest.
        let sorted = deviation.sorted()
        let relative = sorted[Int(0.25 * Double(sorted.count - 1))]
        let threshold = min(relative, absoluteHoldDeviation)
        let minSamples = Int(minDwell * fs)

        var result: [Plateau] = []
        var run = 0
        for i in 0...deviation.count {
            let still = i < deviation.count && deviation[i] < threshold
            if still { run += 1; continue }
            if run >= minSamples {
                let startIdx = i - run
                let delta = orientationDelta(frames, around: startIdx)
                result.append(Plateau(start: frames[startIdx].t,
                                      duration: Double(run) / fs,
                                      orientationDelta: delta))
            }
            run = 0
        }
        return result
    }

    /// Gravity-vector spread (g) above which a wrist is moving, not holding.
    /// A settled wrist sits near 0.01–0.02; a slow drift through a fidgety
    /// setup runs 0.08 and up.
    static let absoluteHoldDeviation: Double = 0.06

    private static func orientationDelta(_ frames: [MotionFrame], around idx: Int) -> Double {
        let back = max(0, idx - Int(0.4 * fs))
        guard back < idx else { return 0 }
        let d = frames[idx].gravity - frames[back].gravity
        return sqrt((d * d).sum())
    }

    /// Condenses the setup window into the feature vector the detector matches on.
    static func signature(_ frames: [MotionFrame]) -> RoutineSignature {
        let holds = plateaus(frames)
        guard !holds.isEmpty else {
            return RoutineSignature(plateauCount: 0, meanDwell: 0,
                                    totalSetupDuration: 0, transitionSharpness: 0,
                                    dwellVariance: 0)
        }
        let dwells = holds.map(\.duration)
        let mean = dwells.reduce(0, +) / Double(dwells.count)
        let variance = dwells.count > 1
            ? dwells.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(dwells.count - 1)
            : 0
        // Sharpness = how abruptly he moves between holds. Deliberate setups
        // have crisp edges; lazy ones blur from one position into the next.
        let sharp = holds.map(\.orientationDelta).reduce(0, +) / Double(holds.count)
        let span = (holds.last!.start + holds.last!.duration) - holds.first!.start

        return RoutineSignature(plateauCount: holds.count,
                                meanDwell: mean,
                                totalSetupDuration: span,
                                transitionSharpness: sharp,
                                dwellVariance: variance.squareRoot())
    }

    // MARK: - Events

    /// Takeaway: sustained rotation above threshold after a settled period.
    static func isTakeaway(_ recent: [MotionFrame], threshold: Double = 1.4) -> Bool {
        guard recent.count >= 6 else { return false }
        return recent.suffix(6).allSatisfy { $0.rotationMagnitude > threshold }
    }

    /// Impact. At 100 Hz a ball strike is shorter than one sample, so we key off
    /// the jerk envelope rather than the acceleration peak itself. Timing
    /// resolution is ±10 ms — fine for tempo, not for anything finer.
    ///
    /// Two things matter here. We skip the first 250 ms after takeaway, because
    /// the takeaway spike itself would otherwise win. And we take the *first*
    /// crossing above threshold rather than the global maximum, so a loud
    /// follow-through or a club drop later in the buffer can't steal the mark.
    static func impactIndex(_ frames: [MotionFrame],
                            from: Int = 0,
                            threshold: Double = wristImpactThreshold) -> Int? {
        impactCrossing(frames, from: from, threshold: threshold)?.index
    }

    /// Where the strike crossed the floor, with the sub-sample fraction of
    /// the way from `index - 1` to `index` at which the jerk envelope crossed.
    /// At 100 Hz a downswing is 25–32 samples, so whole-sample timing alone
    /// carries ±5–7% of ratio jitter before the golfer adds any — under the
    /// "very consistent" band the score awards. Interpolating the crossing is
    /// what puts that band inside what the sensor can resolve.
    static func impactCrossing(_ frames: [MotionFrame],
                               from: Int = 0,
                               threshold: Double = wristImpactThreshold)
        -> (index: Int, fraction: Double, jerk: Double)? {
        let skip = Int(0.25 * fs)
        let start = max(from + skip, 1)
        guard frames.count > start + 2 else { return nil }

        // One absolute jerk floor for every swing was the misclassification
        // machine: a smooth swinger's strike arrives damped through the grip
        // and ducks under any floor set high enough to ignore a vigorous
        // practice swing. The field numbers said so — 275 "rehearsals"
        // against 92 strikes across three range sessions.
        //
        // A strike is not "a big number"; it's a discontinuity that stands
        // out against the swing it happened in. So the floor self-normalises:
        // measure this swing's own jerk texture (its median), and demand a
        // spike several times above it — bounded below so sensor noise can't
        // qualify on a buttery swing, and bounded above so the caller's
        // scaled threshold remains the worst case, never exceeded.
        //
        // And a strike happens at speed. The rotation gate rejects sharp
        // clunks at low rotation — grounding the club, a ball dropped on the
        // pile — which absolute floors happily mistook for impacts.
        var jerks: [Double] = []
        jerks.reserveCapacity(frames.count - start)
        var previous = frames[start - 1].accelMagnitude
        for i in start..<frames.count {
            let mag = frames[i].accelMagnitude
            jerks.append(abs(mag - previous) * fs)
            previous = mag
        }
        let baseline = jerks.sorted()[jerks.count / 2]
        let floor = min(max(threshold * 0.55, baseline * 5.0), threshold * 1.4)
        let peakRot = frames[start...].map(\.rotationMagnitude).max() ?? 0
        let rotGate = peakRot * 0.25

        for (k, jerk) in jerks.enumerated() where jerk > floor {
            let i = start + k
            if frames[i].rotationMagnitude >= rotGate
                || frames[max(0, i - 1)].rotationMagnitude >= rotGate {
                let prev = k > 0 ? jerks[k - 1] : 0
                let span = jerk - prev
                let fraction = span > 0 ? max(0, min(1, (floor - prev) / span)) : 1
                return (i, fraction, jerk)
            }
        }
        return nil
    }

    /// Jerk at one sample, same definition `impactCrossing` uses, so the
    /// detector can ask "is this candidate still the sharpest thing so far"
    /// without recomputing the whole envelope.
    static func jerk(_ frames: [MotionFrame], at i: Int) -> Double {
        guard i > 0, i < frames.count else { return 0 }
        return abs(frames[i].accelMagnitude - frames[i - 1].accelMagnitude) * fs
    }

    /// The moment the club actually started back: walk from the trigger
    /// sample back to the last frame that was genuinely still. The trigger
    /// fires only after rotation has been above threshold for six samples,
    /// which is well into the takeaway, so timing the backswing from it
    /// undercounts every backswing by a variable amount and drags the tempo
    /// ratio below its true value.
    static func trueTakeawayIndex(_ frames: [MotionFrame], trigger: Int,
                                  stillRotation: Double,
                                  maxLookback: TimeInterval = 0.6) -> Int {
        let floor = max(0, trigger - Int(maxLookback * fs))
        var i = trigger
        while i > floor, frames[i - 1].rotationMagnitude > stillRotation { i -= 1 }
        return i
    }

    /// Impact threshold scaled to the swing that's actually happening.
    ///
    /// The discipline thresholds are full-intensity floors — 110 is a FULL
    /// pitching wedge. But nobody swings at full intensity out of the gates: a
    /// warm-up half-seven still strikes the ball, with proportionally less
    /// shock, and a fixed floor silently logs those as rehearsals. Impact
    /// shock scales with clubhead speed, which scales with wrist rotation, so
    /// the floor scales with the swing's own peak rotation instead: a swing at
    /// half the reference intensity earns half the threshold, never below 35%
    /// of base. Separation from rehearsals survives because a ball strike is a
    /// discontinuity an order sharper than a turf brush at the same speed —
    /// the smooth deceleration of a practice swing stays under even the floor.
    static func effectiveImpactThreshold(base: Double,
                                         peakRotation: Double,
                                         referenceRotation: Double) -> Double {
        guard referenceRotation > 0 else { return base }
        let intensity = max(0.35, min(1.0, peakRotation / referenceRotation))
        return base * intensity
    }

    /// Whether the device that produced this window was riding on a body or
    /// sitting on the ground. A pocketed phone during a swing sees sustained
    /// hip rotation and a churning gravity vector; a phone parked by the ball
    /// or under a bag sees near-stillness with, at worst, one sharp
    /// ground-shock transient from the strike a foot away — which is exactly
    /// the transient that would otherwise fake a hip "impact" and turn into a
    /// garbage sequencing number. Median rotation is used so that single spike
    /// cannot vote; a transient moves a mean, not a median.
    static func isOnBody(_ frames: [MotionFrame],
                         rotationFloor: Double = 0.15) -> Bool {
        guard frames.count >= 10 else { return false }
        let rots = frames.map(\.rotationMagnitude).sorted()
        let median = rots[rots.count / 2]
        return median > rotationFloor
    }

    /// Watch accelerometers clip around ±16 g and the Series 7 has no high-g
    /// sensor. If we're pinned, peak values are a floor, not a measurement.
    static func didClip(_ frames: [MotionFrame], limit: Double = 15.6) -> Bool {
        frames.contains { abs($0.accel.x) > limit || abs($0.accel.y) > limit || abs($0.accel.z) > limit }
    }

    // MARK: - Metrics

    static func metrics(frames: [MotionFrame],
                        takeawayIdx: Int,
                        impactIdx: Int,
                        impactFraction: Double = 1.0,
                        discipline: Discipline = .fullSwing,
                        stillRotation: Double = 0.35) -> SwingMetrics {
        var m = SwingMetrics()
        m.discipline = discipline
        guard impactIdx > takeawayIdx, impactIdx < frames.count else { return m }

        // Timing runs on the frames' own timestamps, not on index / 100. The
        // sensor clock is what the samples were taken on; an index assumes a
        // perfect 100 Hz that a busy watch does not deliver, and the two
        // disagree most mid-swing, when the detector is working hardest.
        let startIdx = trueTakeawayIndex(frames, trigger: takeawayIdx,
                                         stillRotation: stillRotation)
        let tStart = frames[startIdx].t
        let tImpact = frames[impactIdx - 1].t
            + (frames[impactIdx].t - frames[impactIdx - 1].t) * impactFraction

        let swing = Array(frames[startIdx...impactIdx])

        // Top of backswing = the LAST sustained quiet moment before impact.
        //
        // This used to take the deepest rotation trough anywhere between
        // takeaway and impact, which is wrong twice over. Address is quieter
        // than the top, so on any swing where the takeaway fired early the
        // "top" landed at address and the downswing swallowed the whole swing;
        // and a single noisy sample could win outright, putting the top a few
        // frames from impact. Measured against 92 real range swings the old
        // rule produced downswings from 0.12 s to 1.03 s — an 84% coefficient
        // of variation, which is not a player's variability, it's a broken
        // detector, and it is why the tempo numbers read 0.29 to 6.58 on
        // swings that felt identical.
        //
        // The physics is a transition, not a minimum: the club momentarily
        // stops at the top, then rotation ramps monotonically to impact. So
        // walk back from impact and take the last stretch that stays quiet —
        // quiet relative to this swing's own downswing peak, so it scales with
        // how hard the swing was, and sustained for three samples so noise
        // can't vote. Same 92 swings: variation falls to 34%.
        var topIdx = takeawayIdx
        var lowest = Double.greatestFiniteMagnitude
        let searchLo = max(takeawayIdx, impactIdx - Int(0.85 * fs))
        let searchHi = impactIdx - Int(0.12 * fs)
        if searchLo < searchHi {
            let downswingPeak = frames[searchLo...impactIdx]
                .map(\.rotationMagnitude).max() ?? 0
            let quiet = downswingPeak * 0.15
            var streak = 0
            var i = searchHi
            while i > searchLo {
                if frames[i].rotationMagnitude < quiet {
                    streak += 1
                    if streak >= 3 { topIdx = i + 2; break }
                } else {
                    streak = 0
                }
                i -= 1
            }
            // Nothing ever went quiet — fall back to the trough, which is at
            // least bounded to the plausible window now.
            if topIdx == takeawayIdx {
                for j in searchLo...searchHi where frames[j].rotationMagnitude < lowest {
                    lowest = frames[j].rotationMagnitude; topIdx = j
                }
            }
            lowest = frames[topIdx].rotationMagnitude
        }

        // Sub-sample the top the same way as impact: where rotation crossed
        // back above the quiet line between topIdx and the next sample.
        var tTop = frames[topIdx].t
        if topIdx + 1 < frames.count, topIdx > takeawayIdx {
            let a = frames[topIdx].rotationMagnitude, b = frames[topIdx + 1].rotationMagnitude
            let quietLine = lowest * 1.8
            if b > a, b > quietLine, a <= quietLine {
                let f = (quietLine - a) / (b - a)
                tTop += (frames[topIdx + 1].t - frames[topIdx].t) * max(0, min(1, f))
            }
        }

        m.backswing = max(0, tTop - tStart)
        m.downswing = max(0, tImpact - tTop)
        m.tempoRatio = m.downswing > 0 ? m.backswing / m.downswing : 0
        m.transitionDwell = dwell(frames, around: topIdx, below: max(0.6, lowest * 1.8))
        m.transitionSharpness = sharpness(frames, at: topIdx)
        if let peak = swing.enumerated().max(by: { $0.element.rotationMagnitude < $1.element.rotationMagnitude }) {
            m.peakRotation = peak.element.rotationMagnitude
            // Hands half of sequencing: how long before impact the wrist peaked.
            m.wristPeakLeadMs = max(0, tImpact - peak.element.t) * 1000
        }
        m.smoothness = smoothnessScore(swing, nominalDuration: discipline.nominalSwingDuration)
        m.clipped = didClip(swing)
        return m
    }

    private static func dwell(_ f: [MotionFrame], around idx: Int, below: Double) -> TimeInterval {
        var lo = idx, hi = idx
        while lo > 0, f[lo - 1].rotationMagnitude < below { lo -= 1 }
        while hi < f.count - 1, f[hi + 1].rotationMagnitude < below { hi += 1 }
        return Double(hi - lo) / fs
    }

    private static func sharpness(_ f: [MotionFrame], at idx: Int) -> Double {
        let w = Int(0.08 * fs)
        guard idx - w >= 0, idx + w < f.count else { return 0 }
        return abs(f[idx + w].rotationMagnitude - f[idx - w].rotationMagnitude) / (Double(2 * w) / fs)
    }

    /// Normalized dimensionless jerk, mapped to 0…100 so it reads as a score.
    /// Speed-independent by construction — a slow smooth swing and a fast smooth
    /// swing both score well.
    /// The duration term is raised to the fifth power, so left raw a 0.4 s
    /// putting stroke and a 1.1 s full swing differ by ~150× before the log
    /// and the short game scores structurally smoother than the long game
    /// from the same player. Duration is expressed relative to the
    /// discipline's nominal window so every discipline is judged on the same
    /// scale — the same reason repeatability carries `repeatabilityScale`.
    private static func smoothnessScore(_ f: [MotionFrame],
                                        nominalDuration: TimeInterval = tracePre) -> Double {
        guard f.count > 3 else { return 0 }
        let mags = f.map(\.accelMagnitude)
        var jerkSq = 0.0
        for i in 1..<mags.count {
            let j = (mags[i] - mags[i - 1]) * fs
            jerkSq += j * j / fs
        }
        let duration = Double(f.count) / fs
        let peak = mags.max() ?? 1
        guard peak > 0, duration > 0, nominalDuration > 0 else { return 0 }
        let relative = duration / nominalDuration
        let dimensionless = (jerkSq * pow(relative, 5) * pow(tracePre, 5) / (peak * peak)).squareRoot()
        return max(0, min(100, 100 - 12 * log10(max(1, dimensionless))))
    }

    // MARK: - Ensemble

    /// Impact-aligned and time-normalized. The normalization is not optional:
    /// without it, a fast swing and a slow swing smear against each other and
    /// you read tempo difference as inconsistency.
    /// Traces are always resampled to `traceLength`, so strokes from one
    /// discipline stack correctly even though the window they came from is
    /// shorter. Traces from *different* disciplines must never be stacked
    /// together — the ensemble would align two different motions on the same
    /// index and read the difference as inconsistency.
    static func normalizedTrace(frames: [MotionFrame], impactIdx: Int,
                                discipline: Discipline = .fullSwing) -> [Double] {
        let pre = Int(discipline.tracePre * fs), post = Int(discipline.tracePost * fs)
        let lo = impactIdx - pre, hi = impactIdx + post
        guard hi < frames.count else { return [] }
        // A strike early in the buffer used to return nothing at all, so the
        // swing silently dropped out of the overlay and the ensemble. Pad the
        // missing lead-in with the first available sample instead — the
        // impact stays exactly where every other trace puts it, and a short
        // lead-in reads as flat, which is what stillness looks like anyway.
        var seg: [Double] = []
        if lo < 0 {
            seg = Array(repeating: frames[0].accelMagnitude, count: -lo)
            seg += frames[0...hi].map(\.accelMagnitude)
        } else {
            seg = frames[lo...hi].map(\.accelMagnitude)
        }
        return resample(seg, to: traceLength)
    }

    /// Test surface: the discipline-normalised smoothness of a raw window,
    /// so the harness can prove two disciplines score the same motion alike.
    static func metricsSmoothnessProbe(_ frames: [MotionFrame], discipline: Discipline) -> Double {
        smoothnessScore(frames, nominalDuration: discipline.nominalSwingDuration)
    }

    static func resample(_ x: [Double], to n: Int) -> [Double] {
        guard x.count > 1, n > 1 else { return x }
        return (0..<n).map { i in
            let pos = Double(i) / Double(n - 1) * Double(x.count - 1)
            let lo = Int(pos), hi = min(lo + 1, x.count - 1)
            let f = pos - Double(lo)
            return x[lo] * (1 - f) + x[hi] * f
        }
    }

    /// Median plus interquartile envelope across a set of normalized traces.
    static func ensemble(_ traces: [[Double]]) -> (median: [Double], low: [Double], high: [Double]) {
        guard let n = traces.first?.count, traces.count > 1 else { return ([], [], []) }
        var med = [Double](), lo = [Double](), hi = [Double]()
        for i in 0..<n {
            let col = traces.compactMap { $0.count == n ? $0[i] : nil }.sorted()
            guard !col.isEmpty else { continue }
            med.append(col[col.count / 2])
            lo.append(col[Int(0.25 * Double(col.count - 1))])
            hi.append(col[Int(0.75 * Double(col.count - 1))])
        }
        return (med, lo, hi)
    }
}
