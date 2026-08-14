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

    var isTrained: Bool { realCount >= 8 }

    mutating func learn(_ sig: RoutineSignature, struck: Bool) {
        if struck {
            real = blend(real, sig, n: realCount); realCount += 1
        } else {
            rehearsal = blend(rehearsal, sig, n: rehearsalCount); rehearsalCount += 1
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
        let toReal = sig.similarity(to: real)
        guard let rehearsal, rehearsalCount >= 8 else { return toReal }
        let toRehearsal = sig.similarity(to: rehearsal)
        return toReal / max(0.001, toReal + toRehearsal)
    }

    static let key = "groove.template"
    static func load() -> RoutineTemplate {
        guard let d = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(RoutineTemplate.self, from: d) else {
            return RoutineTemplate()
        }
        return t
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
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
    private(set) var state: DetectorState = .watching
    private(set) var template = RoutineTemplate.load()
    var config = Config.load()

    /// What the player is practising. Set from the watch before a session
    /// starts, and it changes the detector's numbers rather than just a label:
    /// impact threshold, trace window, and whether audio is touched at all.
    /// A putt crosses 9 g at the wrist where a full iron crosses 110, so
    /// running one discipline's threshold over another's data means the
    /// crossing never happens and the stroke is never recorded.
    var discipline: Discipline = .fullSwing

    /// True once this session has seen its first struck ball.
    private(set) var sessionOpened = false

    private var buffer: [MotionFrame] = []
    private let bufferCapacity = Int(SwingAnalyzer.fs * 12)
    private var settleStart: TimeInterval?
    private var armedAt: TimeInterval?
    private var takeawayIdx: Int?
    private var swingPeakRotation: Double = 0
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
            $0.rotationMagnitude < 0.35 && $0.accelMagnitude < 0.12
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
        swingPeakRotation = 0
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

        if let impact = SwingAnalyzer.impactIndex(buffer, from: takeaway,
                                                  threshold: floor),
           buffer.count - impact > tail {
            complete(takeaway: takeaway, impact: impact)
            return
        }
        // No strike inside the window — this was a rehearsal. Restore audio now
        // rather than waiting; a fast correction beats a cautious prediction.
        if elapsed > swingTimeout { complete(takeaway: takeaway, impact: nil) }
    }

    private func evaluateRecovering(_ f: MotionFrame) {
        guard isStill else { return }
        state = .watching
        settleStart = nil
        takeawayIdx = nil
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
        template.save()
        if struck { sessionOpened = true }

        let swing: Swing
        if let impact {
            var m = SwingAnalyzer.metrics(frames: buffer,
                                          takeawayIdx: takeaway, impactIdx: impact)
            m.discipline = discipline
            swing = Swing(struck: true, routine: sig, armConfidence: confidence,
                          metrics: m,
                          normalizedTrace: SwingAnalyzer.normalizedTrace(
                              frames: buffer, impactIdx: impact,
                              discipline: discipline))
        } else {
            var m = SwingMetrics()
            m.discipline = discipline
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

        delegate?.detectorDidCompleteSwing(swing, wasArmed: armed)
    }
}
