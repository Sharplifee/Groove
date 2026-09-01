import Foundation

/// Learned model of what this player's real pre-shot routine looks like.
///
/// It trains itself. A struck ball produces an impact transient and a rehearsal
/// doesn't, so every swing self-labels after the fact and the template improves
/// with every session without the player ever tagging anything.
struct RoutineTemplate: Codable {
    private(set) var real: RoutineSignature?
    private(set) var realCount = 0
    private(set) var rehearsal: RoutineSignature?
    private(set) var rehearsalCount = 0
    /// Per-feature variance for each class, in `vector` space. Optional so
    /// templates saved before variance existed decode and simply retrain it.
    private(set) var realVar: [Double]?
    private(set) var rehearsalVar: [Double]?

    var isTrained: Bool { realCount >= 8 }

    mutating func learn(_ sig: RoutineSignature, struck: Bool) {
        if struck {
            realVar = blendVar(realVar, mean: real, new: sig, n: realCount)
            real = blend(real, sig, n: realCount); realCount += 1
        } else {
            rehearsalVar = blendVar(rehearsalVar, mean: rehearsal, new: sig, n: rehearsalCount)
            rehearsal = blend(rehearsal, sig, n: rehearsalCount); rehearsalCount += 1
        }
    }

    /// Exponentially weighted per-feature variance, same recency weighting as
    /// the mean so the two stay consistent as a routine drifts.
    private func blendVar(_ existing: [Double]?, mean: RoutineSignature?,
                          new sig: RoutineSignature, n: Int) -> [Double] {
        let x = sig.vector
        guard let mean else { return Array(repeating: 0, count: x.count) }
        let m = mean.vector
        let w = 1.0 / Double(min(n, 40) + 1)
        let base = existing ?? Array(repeating: 0.01, count: x.count)
        return zip(base, zip(x, m)).map { v, xm in
            v * (1 - w) + (xm.0 - xm.1) * (xm.0 - xm.1) * w
        }
    }

    /// Running mean, capped so recent swings keep some weight forever —
    /// a routine drifts over a season and the template should follow it.
    private func blend(_ existing: RoutineSignature?,
                       _ new: RoutineSignature, n: Int) -> RoutineSignature {
        guard let e = existing else { return new }
        let w = 1.0 / Double(min(n, 40) + 1)
        return RoutineSignature(
            plateauCount: Int((Double(e.plateauCount) * (1 - w) + Double(new.plateauCount) * w).rounded()),
            meanDwell: e.meanDwell * (1 - w) + new.meanDwell * w,
            totalSetupDuration: e.totalSetupDuration * (1 - w) + new.totalSetupDuration * w,
            transitionSharpness: e.transitionSharpness * (1 - w) + new.transitionSharpness * w,
            dwellVariance: e.dwellVariance * (1 - w) + new.dwellVariance * w)
    }

    /// Confidence that this setup is a real shot. Falls back to a hand-tuned
    /// prior until enough labelled reps exist.
    func confidence(_ sig: RoutineSignature) -> Double {
        guard let real, isTrained else {
            let byCount = min(1, Double(sig.plateauCount) / 3.0)
            let byDwell = min(1, sig.meanDwell / 0.9)
            return 0.5 * byCount + 0.5 * byDwell
        }
        // With both classes trained, score a per-feature Gaussian
        // log-likelihood ratio. Measured on 367 real labelled range records,
        // the old similarity ratio compressed every swing into 0.48–0.51 —
        // the whole population inside a three-hundredths band, which made the
        // arm threshold a coin flip whatever it was set to. Same features,
        // same information, scored this way: medians land at 0.55 struck vs
        // 0.32 rehearsal. Not a better oracle — the features cap out around
        // AUC 0.67 — but a usable dial instead of a broken one, and each
        // feature is weighted by how tightly the player's own reps cluster
        // on it rather than by hand-picked normalisers.
        if let rehearsal, rehearsalCount >= 8,
           let rv = realVar, let hv = rehearsalVar {
            let x = sig.vector, mr = real.vector, mh = rehearsal.vector
            var s = 0.0
            for i in x.indices {
                let sr = max(rv[i].squareRoot(), 0.03)
                let sh = max(hv[i].squareRoot(), 0.03)
                let dr = (x[i] - mr[i]) / sr
                let dh = (x[i] - mh[i]) / sh
                s += (dh * dh - dr * dr) / 2 + Foundation.log(sh / sr)
            }
            return 1 / (1 + Foundation.exp(-s))
        }
        let toReal = sig.similarity(to: real)
        guard let rehearsal, rehearsalCount >= 8 else { return toReal }
        let toRehearsal = sig.similarity(to: rehearsal)
        return toReal / max(0.001, toReal + toRehearsal)
    }

    private static func key(for d: Discipline) -> String { "groove.template." + d.rawValue }

    static func load(for d: Discipline) -> RoutineTemplate {
        // Migrate the single legacy template into the full-swing slot the
        // first time it's asked for, so nobody loses a trained model.
        if let data = UserDefaults.standard.data(forKey: key(for: d)),
           let t = try? JSONDecoder().decode(RoutineTemplate.self, from: data) {
            return t
        }
        if d == .fullSwing,
           let legacy = UserDefaults.standard.data(forKey: "groove.template"),
           let t = try? JSONDecoder().decode(RoutineTemplate.self, from: legacy) {
            return t
        }
        return RoutineTemplate()
    }

    func save(for d: Discipline) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(for: d))
        }
    }

    /// All four templates, encoded, for shipping to the phone so the learned
    /// model survives a watch reinstall (DECISIONS 33 forces those). Keyed by
    /// discipline rawValue.
    static func exportAll() -> [String: Data] {
        var out: [String: Data] = [:]
        for d in Discipline.allCases {
            if let data = UserDefaults.standard.data(forKey: key(for: d)) { out[d.rawValue] = data }
        }
        return out
    }
}

// MARK: - Detector

enum DetectorState: String { case watching, settling, armed, swinging, recovering }

protocol RoutineDetectorDelegate: AnyObject {
    func detectorDidArm(confidence: Double)
    func detectorDidDisarm()
    /// Takeaway on an ARMED swing — the audio duck fires here, ~1 s before the ball.
    /// A swing that wasn't armed is still captured; it just never touches the audio.
    func detectorDidFireTakeaway(confidence: Double)
    /// Fires for every completed swing, armed or not, struck or not.
    func detectorDidCompleteSwing(_ swing: Swing, wasArmed: Bool)
    /// Fires the instant a strike is confirmed, before the trace tail accrues.
    /// This is what the audio burst must key off — waiting for completion adds
    /// the whole trace-tail plus transfer latency, so the burst slices turf
    /// instead of the strike. Default no-op so existing delegates need not care.
    func detectorDidDetectImpact(wasArmed: Bool)
}

extension RoutineDetectorDelegate {
    func detectorDidDetectImpact(wasArmed: Bool) {}
}

/// # Capture and arming are independent
///
/// An earlier version gated logging behind arming, which meant anything that
/// suppressed the duck also suppressed all data — and made the first-strike
/// gate a deadlock it could never escape. Now every takeaway is tracked and
/// every swing is logged. Arming decides one thing only: whether the audio
/// duck fires. That keeps calibration (ducking off, logging on) coherent.
final class RoutineDetector {

    weak var delegate: RoutineDetectorDelegate?
    /// Diagnostic narration: fired at every decision the detector makes, with
    /// the frame time it made it at. Only wired during a capture; nil costs
    /// nothing on the hot path.
    var onTrace: ((TimeInterval, String) -> Void)?
    private(set) var state: DetectorState = .watching
    private(set) var template = RoutineTemplate.load(for: .fullSwing)
    var config = Config.load()

    /// Replace the live template. Used by the replay tool to reproduce the
    /// exact arming the wrist did in the field; not used in the app.
    func installTemplate(_ t: RoutineTemplate) { template = t }

    /// What the player is practising. Set from the watch before a session
    /// starts, and it changes the detector's numbers rather than just a label:
    /// impact threshold, trace window, and whether audio is touched at all.
    /// A putt crosses 9 g at the wrist where a full iron crosses 110, so
    /// running one discipline's threshold over another's data means the
    /// crossing never happens and the stroke is never recorded.
    /// Rotation below which the wrist counts as still. One source of truth:
    /// the takeaway trigger floors at 1.2× this, and metrics time the backswing
    /// from the last frame under it.
    static let stillnessRotation: Double = 0.35

    var discipline: Discipline = .fullSwing {
        didSet {
            guard discipline != oldValue else { return }
            // Each discipline has its own routine — a putting setup and a
            // full-swing setup are different shapes and must not be averaged
            // into one arming model. Persist the outgoing one, load the
            // incoming one.
            template.save(for: oldValue)
            template = RoutineTemplate.load(for: discipline)
        }
    }

    /// True once this session has seen its first struck ball.
    private(set) var sessionOpened = false

    private var buffer: [MotionFrame] = []
    private let bufferCapacity = Int(SwingAnalyzer.fs * 12)
    private var settleStart: TimeInterval?
    private var armedAt: TimeInterval?
    private var takeawayIdx: Int?
    private var swingPeakRotation: Double = 0
    /// Impact found, tail still accruing. Its existence disables the timeout —
    /// a swing with a detected strike must never be logged as a rehearsal just
    /// because it was slow getting there.
    private var pendingImpact: Int?
    private var pendingImpactFraction: Double = 1.0
    private var recoverStart: TimeInterval?
    private var armConfidence: Double = 0
    private var isArmed = false
    private var wasArmedForThisSwing = false

    /// Plateau segmentation is expensive. Re-running it on every 100 Hz sample
    /// burned CPU and battery for no benefit — 10 Hz is plenty for a hold that
    /// lasts a second or more.
    private var samplesSinceSignature = 0
    private let signatureEvery = 10

    private let settleDwell: TimeInterval = 1.0
    private let armTimeout: TimeInterval = 30
    private let swingTimeout: TimeInterval = 3.0

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        state = .watching
        settleStart = nil; armedAt = nil; takeawayIdx = nil
        pendingImpact = nil; pendingImpactFraction = 1.0; recoverStart = nil; swingPeakRotation = 0
        isArmed = false; wasArmedForThisSwing = false
        armConfidence = 0
        samplesSinceSignature = 0
        // Every session starts closed — this is per-session, not per-install.
        sessionOpened = false
    }

    /// Whether the duck is allowed to fire right now. Audio-only: never affects
    /// whether a swing is recorded.
    private var duckPermitted: Bool {
        guard config.hasCalibrated else { return false }
        if config.gateUntilFirstImpact && !sessionOpened { return false }
        return true
    }

    // MARK: Main loop — one call per 100 Hz sample

    func ingest(_ frame: MotionFrame) {
        buffer.append(frame)

        // The buffer trims from the front once it's full, which shifts every
        // absolute index into it. `takeawayIdx` must move with it — without this
        // the index drifts one position per sample, so by impact it's ~110 off
        // and every metric, the impact search, and the trace all read garbage.
        if buffer.count > bufferCapacity {
            let removed = buffer.count - bufferCapacity
            buffer.removeFirst(removed)
            if let t = takeawayIdx { takeawayIdx = max(0, t - removed) }
        }

        // A takeaway is tracked from any non-swinging state, armed or not.
        if state != .swinging, state != .recovering,
           SwingAnalyzer.isTakeaway(Array(buffer.suffix(8)),
                                    threshold: discipline.takeawayThreshold) {
            beginSwing()
            return
        }

        switch state {
        case .watching, .settling: evaluateSetup(frame)
        case .armed:               evaluateArmed(frame)
        case .swinging:            evaluateSwinging(frame)
        case .recovering:          evaluateRecovering(frame)
        }
    }

    private var isStill: Bool {
        guard buffer.count > 20 else { return false }
        return buffer.suffix(20).allSatisfy {
            $0.rotationMagnitude < Self.stillnessRotation && $0.accelMagnitude < 0.12
        }
    }

    private func evaluateSetup(_ f: MotionFrame) {
        guard isStill else {
            if state == .settling { state = .watching; settleStart = nil }
            return
        }
        if state == .watching { state = .settling; settleStart = f.t; samplesSinceSignature = 0 }
        guard let start = settleStart, f.t - start >= settleDwell else { return }

        samplesSinceSignature += 1
        guard samplesSinceSignature >= signatureEvery else { return }
        samplesSinceSignature = 0

        let sig = SwingAnalyzer.signature(Array(buffer.suffix(Int(SwingAnalyzer.fs * 6))))
        let confidence = template.confidence(sig)
        guard confidence >= config.armThreshold else { return }

        armConfidence = confidence
        armedAt = f.t
        isArmed = true
        state = .armed
        onTrace?(f.t, String(format: "armed (confidence %.2f)", confidence))
        delegate?.detectorDidArm(confidence: confidence)
    }

    private func evaluateArmed(_ f: MotionFrame) {
        guard let a = armedAt, f.t - a > armTimeout else { return }
        disarm()
    }

    private func disarm() {
        isArmed = false
        armedAt = nil
        state = .watching
        settleStart = nil
        delegate?.detectorDidDisarm()
    }

    private func beginSwing() {
        onTrace?(buffer.last?.t ?? 0, "takeaway (armed=\(isArmed))")
        swingPeakRotation = 0
        pendingImpact = nil
        pendingImpactFraction = 1.0
        takeawayIdx = max(0, buffer.count - 8)
        wasArmedForThisSwing = isArmed
        state = .swinging
        // Only an armed swing touches the audio, and only when the gate allows.
        if isArmed && duckPermitted {
            delegate?.detectorDidFireTakeaway(confidence: armConfidence)
        }
    }

    private func evaluateSwinging(_ f: MotionFrame) {
        guard let takeaway = takeawayIdx else { state = .watching; return }
        let elapsed = f.t - buffer[takeaway].t
        let tail = Int(discipline.tracePost * SwingAnalyzer.fs)

        // Running peak, kept incrementally — this is what scales the floor.
        swingPeakRotation = max(swingPeakRotation, f.rotationMagnitude)
        let floor = SwingAnalyzer.effectiveImpactThreshold(
            base: discipline.wristImpactThreshold,
            peakRotation: swingPeakRotation,
            referenceRotation: discipline.referenceRotation)

        if pendingImpact == nil,
           let cross = SwingAnalyzer.impactCrossing(buffer, from: takeaway, threshold: floor) {
            // A crossing is only a strike if it is the sharpest thing in the
            // swing — the self-normalising idea from DECISIONS 39, which until
            // now only held in the harness because live this ran on a growing
            // buffer and locked the first crossing before the real peak
            // existed. Wait for a short lookahead and take the candidate only
            // if nothing sharper follows it; a wrist-cock or grip re-set spikes
            // early and is then beaten by the real strike. But a genuine strike
            // often lands within a few samples of the newest frame, so once the
            // lookahead exists and the candidate still dominates, lock it —
            // and never discard it, since the tail arrives on later ticks.
            let candidate = cross.index
            let confirmFor = Int(0.06 * SwingAnalyzer.fs)
            let haveLookahead = buffer.count - 1 - candidate >= confirmFor
            if haveLookahead {
                // Skip the strike's own ring-down: the transient's rebound one
                // or two samples later is nearly as sharp as the strike itself,
                // and comparing against it rejected every real strike. Look
                // past it for a genuinely separate, sharper event.
                let ringDown = 3
                let lo = candidate + 1 + ringDown
                let hi = candidate + confirmFor + ringDown
                let after = (lo...hi).compactMap {
                    $0 < buffer.count ? SwingAnalyzer.jerk(buffer, at: $0) : nil
                }.max() ?? 0
                if cross.jerk >= after {
                    pendingImpact = candidate
                    pendingImpactFraction = cross.fraction
                    onTrace?(f.t, String(format: "impact found (floor %.0f, peak rot %.1f, idx %d)",
                                         floor, swingPeakRotation, candidate))
                    delegate?.detectorDidDetectImpact(wasArmed: wasArmedForThisSwing)
                }
                // else a sharper event is imminent — keep looking.
            }
            // No lookahead yet: do nothing this tick and re-test next tick, by
            // which point more tail has arrived. The swing timeout still guards
            // against a candidate that never gets its lookahead.
        }
        if let impact = pendingImpact {
            // Strike confirmed; the only thing left is collecting the trace
            // tail. The timeout no longer applies — the old code kept it
            // running, so a slow warm-up swing (or one whose takeaway fired
            // early off a forward press) hit the 3-second limit AFTER its
            // impact had been found and was logged as a rehearsal. A struck
            // ball is a struck ball, however long the swing took to arrive.
            if buffer.count - impact > tail { complete(takeaway: takeaway, impact: impact) }
            return
        }

        // False start: a waggle or club lift at address sustains takeaway-level
        // rotation for the trigger window, then dies. If rotation has collapsed
        // shortly after the trigger with no strike, this was never a swing —
        // abort silently back to watching. No rehearsal is logged and the
        // template learns nothing, because there is nothing to learn from.
        // The window closes at 0.7s so the near-zero rotation of a real
        // transition pause at the top can never be mistaken for a dead waggle.
        if elapsed > 0.35, elapsed < 0.7,
           buffer.suffix(15).allSatisfy({ $0.rotationMagnitude
                                          < discipline.takeawayThreshold * 0.6 }) {
            onTrace?(f.t, "false start aborted — rotation died after the trigger")
            state = .watching
            takeawayIdx = nil
            pendingImpact = nil
            return
        }

        // No strike inside the window — this was a rehearsal. Restore audio now
        // rather than waiting; a fast correction beats a cautious prediction.
        if elapsed > swingTimeout {
            onTrace?(f.t, "no strike inside the window — rehearsal")
            complete(takeaway: takeaway, impact: nil)
        }
    }

    private func evaluateRecovering(_ f: MotionFrame) {
        if recoverStart == nil { recoverStart = f.t }
        // Stillness releases recovery — but stillness alone was the only exit,
        // and a fidgety wrist between range balls (raking the next one over,
        // wind, waggling) could hold the detector in recovery indefinitely,
        // blind to every swing that followed. Time releases it too.
        guard isStill || f.t - (recoverStart ?? f.t) > 2.5 else { return }
        onTrace?(f.t, isStill ? "recovered (still)" : "recovered (timed release)")
        state = .watching
        settleStart = nil
        takeawayIdx = nil
        recoverStart = nil
    }

    // MARK: Completion + self-training

    private func complete(takeaway: Int, impact: Int?) {
        let setupWindow = Array(buffer.prefix(takeaway).suffix(Int(SwingAnalyzer.fs * 6)))
        let sig = SwingAnalyzer.signature(setupWindow)
        let struck = impact != nil

        // Score THIS swing against the template as it stands right now, before
        // learning from it. Reusing `armConfidence` meant an unarmed rehearsal
        // inherited the last armed swing's number — which is precisely the field
        // calibration averages to prove the detector separates them.
        let confidence = template.confidence(sig)

        // The whole self-labeling loop: the ball is the ground truth.
        template.learn(sig, struck: struck)
        template.save(for: discipline)
        if struck { sessionOpened = true }

        // Both verdicts carry the two numbers the verdict itself rode on.
        // Rehearsals used to save empty metrics, which made "were real
        // strikes filed as rehearsals?" unanswerable from an export — 275
        // rehearsals against 92 strikes across three range sessions, and no
        // way to tell which of the 275 had a strike-shaped transient sitting
        // just under the floor. Now every record says how hard the motion
        // was and how sharp its sharpest moment was.
        let swingFrames = Array(buffer.suffix(from: takeaway))
        let observedPeakRot = swingFrames.map(\.rotationMagnitude).max() ?? 0
        var observedPeakJerk = 0.0
        for i in 1..<max(1, swingFrames.count) {
            let j = abs(swingFrames[i].accelMagnitude
                        - swingFrames[i - 1].accelMagnitude) * SwingAnalyzer.fs
            if j > observedPeakJerk { observedPeakJerk = j }
        }

        let swing: Swing
        if let impact {
            var m = SwingAnalyzer.metrics(frames: buffer,
                                          takeawayIdx: takeaway, impactIdx: impact,
                                          impactFraction: pendingImpactFraction,
                                          discipline: discipline,
                                          stillRotation: Self.stillnessRotation)
            m.peakJerk = observedPeakJerk
            swing = Swing(struck: true, routine: sig, armConfidence: confidence,
                          metrics: m,
                          normalizedTrace: SwingAnalyzer.normalizedTrace(
                              frames: buffer, impactIdx: impact,
                              discipline: discipline))
        } else {
            var m = SwingMetrics()
            m.discipline = discipline
            m.peakRotation = observedPeakRot
            m.peakJerk = observedPeakJerk
            swing = Swing(struck: false, routine: sig, armConfidence: confidence,
                          metrics: m, normalizedTrace: [])
        }

        let armed = wasArmedForThisSwing
        isArmed = false
        armedAt = nil
        armConfidence = 0
        wasArmedForThisSwing = false
        state = .recovering
        takeawayIdx = nil
        pendingImpact = nil
        pendingImpactFraction = 1.0
        recoverStart = nil

        onTrace?(buffer.last?.t ?? 0,
                 swing.struck ? "swing complete — STRUCK" : "swing complete — rehearsal")
        delegate?.detectorDidCompleteSwing(swing, wasArmed: armed)
    }
}
