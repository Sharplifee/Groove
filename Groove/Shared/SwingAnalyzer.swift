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

        let sorted = deviation.sorted()
        let threshold = sorted[Int(0.25 * Double(sorted.count - 1))]
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
        let skip = Int(0.25 * fs)
        let start = max(from + skip, 1)
        guard frames.count > start + 2 else { return nil }

        var previous = frames[start - 1].accelMagnitude
        for i in start..<frames.count {
            let mag = frames[i].accelMagnitude
            let jerk = abs(mag - previous) * fs
            previous = mag
            if jerk > threshold { return i }
        }
        return nil
    }

    /// Watch accelerometers clip around ±16 g and the Series 7 has no high-g
    /// sensor. If we're pinned, peak values are a floor, not a measurement.
    static func didClip(_ frames: [MotionFrame], limit: Double = 15.6) -> Bool {
        frames.contains { abs($0.accel.x) > limit || abs($0.accel.y) > limit || abs($0.accel.z) > limit }
    }

    // MARK: - Metrics

    static func metrics(frames: [MotionFrame],
                        takeawayIdx: Int,
                        impactIdx: Int) -> SwingMetrics {
        var m = SwingMetrics()
        guard impactIdx > takeawayIdx, impactIdx < frames.count else { return m }

        let swing = Array(frames[takeawayIdx...impactIdx])

        // Top of backswing = the deepest rotation-rate trough between the two.
        var topIdx = takeawayIdx
        var lowest = Double.greatestFiniteMagnitude
        let searchLo = takeawayIdx + Int(0.25 * fs)
        let searchHi = impactIdx - Int(0.12 * fs)
        if searchLo < searchHi {
            for i in searchLo...searchHi where frames[i].rotationMagnitude < lowest {
                lowest = frames[i].rotationMagnitude; topIdx = i
            }
        }

        m.backswing = Double(topIdx - takeawayIdx) / fs
        m.downswing = Double(impactIdx - topIdx) / fs
        m.tempoRatio = m.downswing > 0 ? m.backswing / m.downswing : 0
        m.transitionDwell = dwell(frames, around: topIdx, below: max(0.6, lowest * 1.8))
        m.transitionSharpness = sharpness(frames, at: topIdx)
        m.peakRotation = swing.map(\.rotationMagnitude).max() ?? 0
        m.smoothness = smoothnessScore(swing)
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
    private static func smoothnessScore(_ f: [MotionFrame]) -> Double {
        guard f.count > 3 else { return 0 }
        let mags = f.map(\.accelMagnitude)
        var jerkSq = 0.0
        for i in 1..<mags.count {
            let j = (mags[i] - mags[i - 1]) * fs
            jerkSq += j * j / fs
        }
        let duration = Double(f.count) / fs
        let peak = mags.max() ?? 1
        guard peak > 0, duration > 0 else { return 0 }
        let dimensionless = (jerkSq * pow(duration, 5) / (peak * peak)).squareRoot()
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
        guard lo >= 0, hi < frames.count else { return [] }
        let seg = frames[lo...hi].map(\.accelMagnitude)
        return resample(seg, to: traceLength)
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
