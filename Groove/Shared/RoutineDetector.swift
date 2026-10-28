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
    /// The phone should open its microphone ring now; a swing may be seconds
    /// away. `routine` is true when the learned pre-shot model fired (the
    /// "it recognised you" moment, worth a haptic), false when it is simply
    /// the player having settled over the ball in every-swing mode.
    func detectorDidArm(confidence: Double, routine: Bool)
    func detectorDidDisarm()
    /// Takeaway on a swing the audio should follow — the duck fires here,
    /// ~1 s before the ball. A swing that didn't qualify is still captured;
    /// it just never touches the audio.
    func detectorDidFireTakeaway(confidence: Double)
    /// Fires for every logged motion — strike, practice swing or waggle.
    /// `wasArmed` means the audio was engaged for it and needs restoring if
    /// no strike followed.
    func detectorDidCompleteSwing(_ swing: Swing, wasArmed: Bool)
    /// Fires the instant a strike is confirmed, before the trace tail accrues.
    /// This is what the audio burst must key off — waiting for completion adds
    /// the whole trace-tail plus transfer latency, so the burst slices turf
    /// instead of the strike. Default no-op so existing delegates need not care.
    func detectorDidDetectImpact(wasArmed: Bool, lag: TimeInterval)
    /// A motion ran and was not a swing of any kind — walking, raking a ball
    /// over, teeing up. Counted so the face can say "ignored 14 movements";
    /// never logged. `wasArmed` carries the same restore duty as above.
    func detectorDidDiscardMotion(reason: String, wasArmed: Bool)
    /// Any motion has begun, ducked or not — the face's "swinging" state.
    func detectorDidStartMotion(fromAddress: Bool)
    /// Recovery after a motion has ended; the face goes back to "watching".
    func detectorDidRecover()
}

extension RoutineDetectorDelegate {
    func detectorDidDetectImpact(wasArmed: Bool, lag: TimeInterval) {}
    func detectorDidDiscardMotion(reason: String, wasArmed: Bool) {}
    func detectorDidStartMotion(fromAddress: Bool) {}
    func detectorDidRecover() {}
}

/// # How a motion becomes a record
///
/// The wrist stream is cut into *episodes*: a run of rotation above the
/// discipline's takeaway trigger, closed when the wrist drops under the end
/// threshold and stays there. Nothing is decided about an episode until it
/// closes (a strike is the one exception — it is confirmed live so the audio
/// burst can fire). At close the whole motion is in hand and is classified by
/// its shape:
///
/// - **strike** — an impact transient was confirmed inside it;
/// - **practice** — no strike, but the motion is swing-shaped: one dominant
///   speed peak preceded by a backswing and followed by a finish, inside the
///   span a swing can take, above the rotation a swing must reach;
/// - **waggle** — small and short, from a settled address, back to stillness;
/// - **discarded** — everything else. Walking, raking, teeing up. Counted,
///   never logged, and never allowed to teach the routine model.
///
/// The old engine had no notion of shape: any wrist motion lasting three
/// seconds without a strike was logged as a practice swing. Walking between
/// balls was a practice swing. That is where three sessions' 275 "practice
/// swings" came from, and it poisoned the routine model's idea of what a
/// rehearsal looks like.
///
/// # Capture and audio are independent
///
/// Every episode is tracked and every swing is logged, armed or not. Arming
/// decides one thing only: whether the audio duck fires. Calibration (ducking
/// off, logging on) stays coherent because of this.
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
    /// exact arming the wrist did in the field; not used in the app. From
    /// then on the template is never persisted — a replay must not write
    /// into the replaying machine's defaults, or the next replay of an older
    /// capture (no template of its own) inherits it and arms differently.
    func installTemplate(_ t: RoutineTemplate) { template = t; persistsTemplate = false }
    private var persistsTemplate = true

    /// Rotation below which the wrist counts as still. One source of truth:
    /// the takeaway trigger floors at 1.2× this, and metrics time the backswing
    /// from the last frame under it.
    static let stillnessRotation: Double = 0.35
    /// |user acceleration| ceiling for stillness, g.
    static let stillnessAccel: Double = 0.12
    /// How long the wrist must sit under the end threshold for a motion to
    /// have finished. Longer than any pause at the top of a backswing.
    static let episodeEndHold: TimeInterval = 0.3
    /// Stillness required before a motion for it to count as "from address".
    static let addressSettle: TimeInterval = 0.6
    /// A motion still running past this is force-closed and judged.
    static let maxEpisode: TimeInterval = 5.0

    var discipline: Discipline = .fullSwing {
        didSet {
            guard discipline != oldValue else { return }
            // Each discipline has its own routine — a putting setup and a
            // full-swing setup are different shapes and must not be averaged
            // into one arming model. Persist the outgoing one, load the
            // incoming one.
            guard persistsTemplate else { return }
            template.save(for: oldValue)
            template = RoutineTemplate.load(for: discipline)
        }
    }

    /// True once this session has seen its first struck ball.
    private(set) var sessionOpened = false
    /// Motions that ran and were not swings this session.
    private(set) var discardedCount = 0

    // MARK: Buffer

    private var buffer: [MotionFrame] = []
    private let bufferCapacity = Int(SwingAnalyzer.fs * 12)
    /// Consecutive frames of stillness ending at the newest frame.
    private var stillRun = 0
    /// Still/moving history for the last 2 s, one bit per frame, so "was the
    /// player settled before this motion" reads over a window rather than
    /// from the run that happened to end last. A forward press or a last
    /// look at the target breaks stillness for a few frames right before the
    /// takeaway — the commonest real pre-shot pattern — and must not turn a
    /// swing from address into one "on the walk".
    private var stillHistory: [Bool] = []
    private let stillWindow = 200

    // MARK: Arming (audio only)

    private var settleStart: TimeInterval?
    private var armedAt: TimeInterval?
    private var armConfidence: Double = 0
    private var isArmed = false
    private var armedByRoutine = false
    private var samplesSinceSignature = 0
    private let signatureEvery = 10
    private let settleDwell: TimeInterval = 1.0
    private let armTimeout: TimeInterval = 30

    // MARK: Open episode

    private struct Episode {
        var startIdx: Int                 // absolute buffer index, trimmed along
        var startT: TimeInterval
        var startedFromAddress: Bool
        var audioEngaged = false
        var peakRot = 0.0
        var peakRotIdx = 0
        var peakAccel = 0.0
        var clipped = false
        /// Per-frame jerk from the search start; index 0 == searchStartIdx.
        var jerks: [Double] = []
        var searchStartIdx = 0
        var jerkBaseline = 0.0
        var sinceBaseline = 0
        var candidate: (idx: Int, fraction: Double, jerk: Double)?
        var impact: (idx: Int, fraction: Double, jerk: Double)?
        var impactScore = 0.0
        var quietRun = 0
        /// Frames under the takeaway trigger: a looser second way to close.
        var lowRun = 0
        var restoredEarly = false
        /// Duck wanted at takeaway, decided a quarter-second in (see below).
        var duckPending = false
        /// Frame time the takeaway trigger fired (eight frames after startT).
        var triggerT: TimeInterval = 0
        /// Rotation lobes, kept live so a walk can be recognised (and its
        /// duck released) before the episode closes. Each lobe's own peak is
        /// recorded; `lobes` counts those that stand at least 55% of the
        /// motion's peak so far. A forward press that merged into the
        /// episode (1–2 rad/s against a 20 rad/s swing) drops out the moment
        /// the real swing arrives; a walk's strides are all alike and all
        /// count; a backswing's lobe (~40% of the downswing) never counts, so
        /// a swing is one lobe.
        var lobePeaks: [Double] = []
        var inLobe = false
        var lobes: Int { lobePeaks.filter { $0 >= peakRot * 0.55 }.count }
    }
    private var episode: Episode?
    private var recoverStart: TimeInterval?
    /// A struck swing closes while the follow-through is still shedding
    /// speed. The remainder of that follow-through must not start a new
    /// motion, so no takeaway is tracked until the wrist has dropped under
    /// the trigger at least once.
    private var awaitingDrop = false

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        state = .watching
        settleStart = nil; armedAt = nil; armConfidence = 0
        isArmed = false; armedByRoutine = false
        samplesSinceSignature = 0
        episode = nil; recoverStart = nil; awaitingDrop = false; rearmNeedsMotion = false
        stillRun = 0; stillHistory.removeAll(keepingCapacity: true)
        sessionOpened = false
        discardedCount = 0
    }

    /// Whether the duck is allowed to fire right now. Audio-only: never affects
    /// whether a swing is recorded.
    private var duckPermitted: Bool {
        switch config.duckMode {
        case .off: return false
        case .routineOnly: guard config.hasCalibrated else { return false }
        case .everySwing: break
        }
        guard discipline.ducksAudio else { return false }
        // The first-ball gate exists because an untrained routine isn't
        // consistent during warm-up. Every-swing mode has no routine to be
        // inconsistent; gating it just silenced the first real shot of every
        // session in the default mode.
        if config.duckMode == .routineOnly, config.gateUntilFirstImpact, !sessionOpened { return false }
        return true
    }

    // MARK: Main loop — one call per 100 Hz sample

    func ingest(_ frame: MotionFrame) {
        buffer.append(frame)
        // Trim in chunks, not one frame at a time: removeFirst shifts the
        // whole array, and doing that a hundred times a second on a 1,200
        // frame buffer is the kind of silent per-frame cost that lagged the
        // wrist before. Two seconds of slack costs nothing.
        if buffer.count > bufferCapacity + 200 {
            let removed = buffer.count - bufferCapacity
            buffer.removeFirst(removed)
            // Absolute indices into a rolling buffer must move with it, or
            // they drift one position per sample and every metric reads
            // garbage.
            if episode != nil {
                episode!.startIdx = max(0, episode!.startIdx - removed)
                episode!.searchStartIdx = max(0, episode!.searchStartIdx - removed)
                episode!.peakRotIdx = max(0, episode!.peakRotIdx - removed)
                if let c = episode!.candidate { episode!.candidate = (max(0, c.idx - removed), c.fraction, c.jerk) }
                if let i = episode!.impact { episode!.impact = (max(0, i.idx - removed), i.fraction, i.jerk) }
            }
        }

        let still = frame.rotationMagnitude < Self.stillnessRotation
            && frame.accelMagnitude < Self.stillnessAccel
        stillRun = still ? stillRun + 1 : 0
        stillHistory.append(still)
        if stillHistory.count > stillWindow { stillHistory.removeFirst(stillHistory.count - stillWindow) }
        // Settled: at least 0.6 s of stillness inside the last 1.5 s. Read
        // every frame (cheap: 150 bools) so it is current at the trigger.
        let recent = stillHistory.suffix(150)
        let settledBefore = Double(recent.filter { $0 }.count) / SwingAnalyzer.fs >= Self.addressSettle

        if episode != nil {
            advanceEpisode(frame)
            return
        }
        if awaitingDrop {
            guard frame.rotationMagnitude < discipline.takeawayThreshold else { return }
            awaitingDrop = false
        }

        // A takeaway is tracked from any non-swinging state, armed or not.
        if SwingAnalyzer.isTakeaway(Array(buffer.suffix(8)),
                                    threshold: discipline.takeawayThreshold) {
            beginEpisode(settledBefore: settledBefore)
            return
        }

        switch state {
        case .watching, .settling: evaluateSetup(frame, still: still)
        case .armed:               evaluateArmed(frame)
        case .recovering:          evaluateRecovering(frame)
        case .swinging:            state = .watching     // unreachable: episode owns it
        }
    }

    // MARK: Setup / arming

    private func evaluateSetup(_ f: MotionFrame, still: Bool) {
        guard still, stillRun > 20 else {
            if state == .settling { state = .watching; settleStart = nil }
            rearmNeedsMotion = false
            return
        }
        if state == .watching { state = .settling; settleStart = f.t; samplesSinceSignature = 0 }
        guard let start = settleStart else { return }
        let settledFor = f.t - start

        // Arming exists for the audio alone: it opens the phone mic ahead of
        // a swing and, in routine mode, says the model recognised the setup.
        // When the music can't be touched there is nothing to arm for.
        switch config.duckMode {
        case .off:
            return
        case .everySwing:
            // Being over the ball IS the signal. Open the mic the moment the
            // player has settled, so the ring is live before the takeaway.
            // No routine model involved, no haptic. Not when the duck can't
            // fire anyway (putting, ducking off): that opened the phone's mic
            // for every putt on the green for nothing.
            guard duckPermitted, !rearmNeedsMotion else { return }
            if settledFor >= Self.addressSettle, !isArmed { arm(confidence: 1, routine: false, at: f.t) }
            return
        case .routineOnly:
            guard config.hasCalibrated else { return }
        }

        guard settledFor >= settleDwell else { return }
        samplesSinceSignature += 1
        guard samplesSinceSignature >= signatureEvery else { return }
        samplesSinceSignature = 0

        let sig = SwingAnalyzer.signature(Array(buffer.suffix(Int(SwingAnalyzer.fs * 6))))
        let confidence = template.confidence(sig)
        guard confidence >= config.armThreshold else { return }
        arm(confidence: confidence, routine: true, at: f.t)
    }

    private func arm(confidence: Double, routine: Bool, at t: TimeInterval) {
        armConfidence = confidence
        armedAt = t
        isArmed = true
        armedByRoutine = routine
        state = .armed
        onTrace?(t, routine ? String(format: "armed by routine (confidence %.2f)", confidence)
                            : "armed (settled at address)")
        delegate?.detectorDidArm(confidence: confidence, routine: routine)
    }

    /// Set when an arm times out while the player is still standing still:
    /// re-arming on the same stillness would thrash the phone's audio session
    /// every 30 s for as long as they stood there. They have to move first.
    private var rearmNeedsMotion = false

    private func evaluateArmed(_ f: MotionFrame) {
        guard let a = armedAt, f.t - a > armTimeout else { return }
        rearmNeedsMotion = stillRun > 20
        disarm()
    }

    private func disarm() {
        isArmed = false
        armedByRoutine = false
        armedAt = nil
        state = .watching
        settleStart = nil
        delegate?.detectorDidDisarm()
    }

    private func evaluateRecovering(_ f: MotionFrame) {
        if recoverStart == nil { recoverStart = f.t }
        // Stillness releases recovery; time releases it too, so a fidgety
        // wrist between balls cannot hold the detector blind.
        guard stillRun > 20 || f.t - (recoverStart ?? f.t) > 2.5 else { return }
        onTrace?(f.t, stillRun > 20 ? "recovered (still)" : "recovered (timed release)")
        state = .watching
        settleStart = nil
        recoverStart = nil
        delegate?.detectorDidRecover()
    }

    // MARK: Episode

    private func beginEpisode(settledBefore: Bool) {
        let t = buffer.last?.t ?? 0
        let startIdx = max(0, buffer.count - 8)
        var e = Episode(startIdx: startIdx, startT: buffer[startIdx].t, startedFromAddress: settledBefore)
        e.searchStartIdx = startIdx + Int(discipline.impactSearchDelay * SwingAnalyzer.fs)
        e.peakRotIdx = startIdx

        // Audio. Every-swing mode ducks any takeaway from a settled address;
        // routine mode ducks only when the learned model armed first. Both
        // need the gate and the discipline to allow it.
        let engage: Bool
        switch config.duckMode {
        case .everySwing:  engage = settledBefore && duckPermitted
        case .routineOnly: engage = isArmed && armedByRoutine && duckPermitted
        case .off:         engage = false
        }
        e.duckPending = engage
        e.triggerT = t
        episode = e
        state = .swinging
        onTrace?(t, "takeaway (from address=\(settledBefore), armed=\(isArmed), duck pending=\(engage))")
        delegate?.detectorDidStartMotion(fromAddress: settledBefore)
    }

    /// How far past the TRIGGER frame the duck decision waits (the episode
    /// starts eight frames earlier, so measuring from there under-waited by
    /// 80 ms and the short game was judged ~100 ms in, while a chip waggle is
    /// still rising). A waggle is a lift that is already falling back by a
    /// quarter-second; a backswing of any discipline is still building.
    /// Leaves 600 ms+ before a full-swing impact.
    private var duckDecisionDelay: TimeInterval { 0.25 }

    /// Fires the duck if, a quarter-second in, the wrist is still going back
    /// — rotation holding or rising against 100 ms earlier. A waggle has
    /// peaked and is dying by now, so it never ducks; a takeaway of any
    /// speed is still building. The cost is a quarter-second of lead time;
    /// the gain is that a player with three waggles before every shot keeps
    /// their music.
    private func decideDuck(_ e: inout Episode, at i: Int, now t: TimeInterval) {
        e.duckPending = false
        let back = max(e.startIdx, i - 10)
        let rising = buffer[i].rotationMagnitude >= 0.85 * buffer[back].rotationMagnitude
            && buffer[i].rotationMagnitude >= discipline.takeawayThreshold
        if rising {
            e.audioEngaged = true
            onTrace?(t, "duck — takeaway still building")
            delegate?.detectorDidFireTakeaway(confidence: armConfidence)
        } else {
            onTrace?(t, "no duck — motion already dying, a waggle")
        }
    }

    private func advanceEpisode(_ f: MotionFrame) {
        guard var e = episode else { return }
        let i = buffer.count - 1
        let rot = f.rotationMagnitude
        let elapsed = f.t - e.startT

        if e.duckPending, f.t - e.triggerT >= duckDecisionDelay { decideDuck(&e, at: i, now: f.t) }

        if rot > e.peakRot { e.peakRot = rot; e.peakRotIdx = i }
        e.peakAccel = max(e.peakAccel, f.accelMagnitude)
        if abs(f.accel.x) > 15.6 || abs(f.accel.y) > 15.6 || abs(f.accel.z) > 15.6 { e.clipped = true }

        // Lobe counting: a swing has one dominant speed lobe; a walk has one
        // per stride. Tracked live so a walk can release the duck early.
        if rot >= max(e.peakRot * 0.55, discipline.takeawayThreshold) {
            if !e.inLobe { e.inLobe = true; e.lobePeaks.append(rot) }
            else { e.lobePeaks[e.lobePeaks.count - 1] = max(e.lobePeaks[e.lobePeaks.count - 1], rot) }
        } else if rot < e.peakRot * 0.3 {
            e.inLobe = false
        }

        // Impact search — incremental, one new jerk per frame.
        if e.impact == nil, i >= e.searchStartIdx, i > 0 {
            e.jerks.append(SwingAnalyzer.jerk(buffer, at: i))
            e.sinceBaseline += 1
            if e.jerkBaseline == 0 || e.sinceBaseline >= 10 {
                e.jerkBaseline = e.jerks.sorted()[e.jerks.count / 2]
                e.sinceBaseline = 0
            }
            // The floor scales with the swing's peak, but the running peak
            // during the backswing is a backswing number: at 0.35 s in it put
            // the floor at its minimum and a wrist-cock step became a strike
            // confirmed mid-backswing, burst and all. A strike cannot precede
            // swing speed, so until the motion has reached it the floor is
            // judged at the swing-speed floor and no candidate is taken.
            let atSwingSpeed = e.peakRot >= discipline.swingPeakFloor
            let threshold = SwingAnalyzer.effectiveImpactThreshold(
                base: discipline.wristImpactThreshold,
                peakRotation: max(e.peakRot, discipline.swingPeakFloor),
                referenceRotation: discipline.referenceRotation)
            // Two floors, both must clear. The global one (median texture of
            // the whole motion, ×5, bounded by the discipline threshold) is
            // what the field data tuned. The local one is physics the global
            // floor can't see: a hard downswing's centripetal acceleration
            // ramps steeply enough that at 100 Hz a smooth swing shows tens of
            // g/s of "jerk" with no ball at all. A strike is a discontinuity
            // against the motion immediately before it — the fastest part of
            // the swing — so the spike must also stand several times above
            // the jerk of the preceding 120 ms.
            let local = SwingAnalyzer.localJerkLevel(e.jerks)
            let floor = max(SwingAnalyzer.strikeFloor(threshold: threshold, baseline: e.jerkBaseline),
                            local * SwingAnalyzer.localStrikeMultiple)
            let rotGate = e.peakRot * 0.25
            let jerk = e.jerks[e.jerks.count - 1]
            let prev = e.jerks.count > 1 ? e.jerks[e.jerks.count - 2] : 0
            let atSpeed = rot >= rotGate || buffer[max(0, i - 1)].rotationMagnitude >= rotGate
            // Saturating the accelerometer is a strike in its own right —
            // nothing without a ball pins ±16 g — but only at speed.
            let saturated = abs(f.accel.x) > 15.6 || abs(f.accel.y) > 15.6 || abs(f.accel.z) > 15.6
            // Nothing with three speed lobes behind it is a swing, so nothing
            // in it is a ball — the end of a walk gets no strike candidate.
            if (jerk > floor || saturated) && atSpeed && atSwingSpeed && e.lobes <= 2 {
                let span = jerk - prev
                let fraction = span > 0 ? max(0, min(1, (floor - prev) / span)) : 1
                if let c = e.candidate {
                    // A sharper event after the candidate's own ring-down is
                    // the real strike; the earlier one was a wrist-cock or a
                    // re-set.
                    if i > c.idx + 3, jerk > c.jerk { e.candidate = (i, fraction, jerk) }
                } else {
                    e.candidate = (i, fraction, jerk)
                }
            }
            // Confirm the candidate once a short lookahead has arrived with
            // nothing sharper in it (its own ring-down excluded).
            if let c = e.candidate, i - c.idx >= Int(0.06 * SwingAnalyzer.fs) + 3 {
                // Shape check now that the samples after the candidate exist:
                // a ramp that merely crossed the floor is not a strike.
                let clippedHere = abs(buffer[c.idx].accel.x) > 15.6 || abs(buffer[c.idx].accel.y) > 15.6
                    || abs(buffer[c.idx].accel.z) > 15.6
                guard clippedHere || SwingAnalyzer.isSpike(buffer, at: c.idx) else {
                    onTrace?(f.t, String(format: "candidate at %d rejected — a ramp, not a spike", c.idx))
                    e.candidate = nil
                    episode = e
                    return
                }
                e.impact = c
                let localAtStrike = SwingAnalyzer.localJerkLevel(Array(e.jerks.prefix(c.idx - e.searchStartIdx + 1)))
                e.impactScore = SwingAnalyzer.strikeScore(jerk: c.jerk, baseline: max(localAtStrike, e.jerkBaseline),
                                                          threshold: threshold, clipped: e.clipped)
                onTrace?(f.t, String(format: "impact found (floor %.0f, base %.0f, jerk %.0f, peak rot %.1f, score %.2f)",
                                     floor, e.jerkBaseline, c.jerk, e.peakRot, e.impactScore))
                delegate?.detectorDidDetectImpact(wasArmed: e.audioEngaged && !e.restoredEarly,
                                                  lag: f.t - buffer[c.idx].t)
            }
        }

        // Release the duck early when the motion has already shown it is not
        // a swing: too many strides, or simply too long. A fast correction
        // beats a cautious prediction — the restore is what the player hears.
        if e.audioEngaged, !e.restoredEarly, e.impact == nil,
           e.lobes >= 3 || elapsed > discipline.maxSwingDuration {
            e.restoredEarly = true
            onTrace?(f.t, e.lobes >= 3 ? "audio restored early — striding, not swinging"
                                       : "audio restored early — too long to be a swing")
            delegate?.detectorDidDiscardMotion(reason: "early restore", wasArmed: true)
        }

        // Closing: quiet for the hold, with the trace tail collected if a
        // strike is pending; or hard timeout.
        // Closing. Two ways a motion ends: the wrist goes properly quiet for
        // the hold, or it drops under the takeaway trigger and idles there
        // for a second — a player fidgeting at 0.8 rad/s after a swing has
        // finished the swing, and waiting for true stillness would run the
        // episode into the hard limit and throw the swing away. Either way
        // the trace tail is collected first if a strike is pending.
        // After a strike the swing is over once the follow-through has shed
        // half its speed; whatever the wrist does next — walking straight to
        // the next ball — is a new motion, not part of this one. Without this
        // a strike followed by a walk ran into the hard limit as one episode.
        let quietLine = e.impact != nil
            ? max(discipline.episodeEndThreshold, e.peakRot * 0.5)
            : discipline.episodeEndThreshold
        let quiet = rot < quietLine
        e.quietRun = quiet ? e.quietRun + 1 : 0
        e.lowRun = rot < discipline.takeawayThreshold ? e.lowRun + 1 : 0
        let held = Double(e.quietRun) / SwingAnalyzer.fs >= Self.episodeEndHold
        let idled = Double(e.lowRun) / SwingAnalyzer.fs >= 1.0
        let tailDone = e.impact.map { i - $0.idx >= Int(discipline.tracePost * SwingAnalyzer.fs) } ?? true
        let forced = elapsed >= Self.maxEpisode
        if idled, !held { e.quietRun = e.lowRun }
        episode = e
        if (held || idled) && tailDone {
            close(forced: false)
        } else if forced, tailDone {
            close(forced: true)
        } else if forced, e.impact != nil,
                  elapsed >= Self.maxEpisode + discipline.tracePost + 0.2 {
            // Tail still due past the hard limit: a little more, never forever.
            close(forced: true)
        }
    }

    // MARK: Completion + self-training

    private func close(forced: Bool) {
        guard let e = episode else { return }
        episode = nil
        awaitingDrop = true
        let now = buffer.last?.t ?? 0
        // Where the motion actually ended. For a strike the quiet line was
        // raised to half the peak so the walk-off starts a new motion, which
        // means quietRun began counting during the follow-through — so walk
        // back from the newest frame to the last one still above the normal
        // end line instead, and "duration" means the same thing for every
        // kind: takeaway to the end of the follow-through.
        var lastMovingIdx = max(e.startIdx, buffer.count - 1 - (forced ? 0 : e.quietRun))
        if e.impact != nil, !forced {
            var k = buffer.count - 1
            while k > e.startIdx, buffer[k].rotationMagnitude < discipline.episodeEndThreshold { k -= 1 }
            lastMovingIdx = max(lastMovingIdx, k)
        }
        let duration = buffer[lastMovingIdx].t - e.startT
        let audio = e.audioEngaged && !e.restoredEarly

        let verdict = classify(e, lastMovingIdx: lastMovingIdx, duration: duration, forced: forced)
        onTrace?(now, String(format: "motion closed: %@ (%.2fs, peak %.1f rad/s, lobes %d, from address %@)",
                             verdict.rawValue, duration, e.peakRot, e.lobes,
                             e.startedFromAddress ? "yes" : "no"))

        // Arming is consumed by whatever motion followed it.
        let wasArmed = isArmed
        isArmed = false; armedByRoutine = false; armedAt = nil; armConfidence = 0
        state = .recovering
        recoverStart = nil
        settleStart = nil

        // The phone opened its mic at the arm event; if this motion never
        // engaged the audio (putting, the gate, a discard) nothing downstream
        // would close it, and the record tier sat open until the next ducked
        // swing's tail. Tell it to stand down.
        if wasArmed, !audio { delegate?.detectorDidDisarm() }

        switch verdict {
        case .discarded:
            discardedCount += 1
            delegate?.detectorDidDiscardMotion(reason: "not a swing", wasArmed: audio)
            return
        case .strike, .practice, .waggle:
            break
        }

        let setupWindow = Array(buffer.prefix(e.startIdx).suffix(Int(SwingAnalyzer.fs * 6)))
        let sig = SwingAnalyzer.signature(setupWindow)
        // Score THIS motion against the template as it stands, before
        // learning from it.
        let confidence = template.confidence(sig)
        let kind: SwingKind = verdict == .strike ? .strike : (verdict == .practice ? .practice : .waggle)

        // Only genuine swings from a settled address may teach the routine
        // model. A waggle has no routine before it worth learning, and a
        // practice swing taken on the walk is not a rehearsal of anything.
        if kind != .waggle, e.startedFromAddress {
            template.learn(sig, struck: kind == .strike)
            if persistsTemplate { template.save(for: discipline) }
        }
        if kind == .strike { sessionOpened = true }

        let swing = build(kind: kind, episode: e, lastMovingIdx: lastMovingIdx,
                          duration: duration, signature: sig, confidence: confidence)
        onTrace?(now, "swing complete — " + (kind == .strike ? "STRUCK" : kind.rawValue)
                 + String(format: " (tempo %.2f, effort %.2f)", swing.metrics.tempoRatio, swing.metrics.effort ?? 0))
        delegate?.detectorDidCompleteSwing(swing, wasArmed: audio)
    }

    private enum Verdict: String { case strike, practice, waggle, discarded }

    private func classify(_ e: Episode, lastMovingIdx: Int, duration: TimeInterval, forced: Bool) -> Verdict {
        if e.impact != nil { return .strike }
        let d = discipline
        let rots = buffer[e.startIdx...lastMovingIdx].map(\.rotationMagnitude).sorted()
        let median = rots.isEmpty ? 0 : rots[rots.count / 2]
        let peakiness = median > 0 ? e.peakRot / median : .infinity
        let peakPos = Double(e.peakRotIdx - e.startIdx) / max(1, Double(lastMovingIdx - e.startIdx))

        // A waggle: started from address, never reached swing speed, over
        // quickly, back to stillness.
        if e.startedFromAddress, e.peakRot < d.swingPeakFloor, duration <= 1.5, !forced {
            return .waggle
        }

        let swingShaped = !forced
            && duration >= d.minSwingDuration && duration <= d.maxSwingDuration
            && e.peakRot >= d.swingPeakFloor
            && peakiness >= 2.2
            && peakPos >= 0.2
            && e.lobes <= 2
        return swingShaped ? .practice : .discarded
    }

    private func build(kind: SwingKind, episode e: Episode, lastMovingIdx: Int,
                       duration: TimeInterval, signature sig: RoutineSignature,
                       confidence: Double) -> Swing {
        let d = discipline
        // Strikes align on the ball; practice swings on their own speed
        // peak, which is where the ball would have been.
        let alignIdx = e.impact?.idx ?? e.peakRotIdx
        let fraction = e.impact?.fraction ?? 1.0

        var m: SwingMetrics
        var trace: [Double] = []
        if kind != .waggle, alignIdx > e.startIdx + 2 {
            m = SwingAnalyzer.metrics(frames: buffer, takeawayIdx: e.startIdx, impactIdx: alignIdx,
                                      impactFraction: fraction, discipline: d,
                                      stillRotation: Self.stillnessRotation)
            trace = SwingAnalyzer.normalizedTrace(frames: buffer, impactIdx: alignIdx, discipline: d)
            // Backswing sweep: rotation integrated from the true start to the
            // top. A length proxy — a half swing and a full swing separate
            // on this even when their speeds overlap.
            let start = SwingAnalyzer.trueTakeawayIndex(buffer, trigger: e.startIdx,
                                                        stillRotation: Self.stillnessRotation)
            let tTop = buffer[alignIdx].t - m.downswing
            var sweep = 0.0
            var k = start + 1
            while k <= alignIdx, buffer[k].t <= tTop {
                sweep += buffer[k].rotationMagnitude * (buffer[k].t - buffer[k - 1].t); k += 1
            }
            m.backswingSweep = sweep
        } else {
            m = SwingMetrics()
            m.discipline = d
            m.peakRotation = e.peakRot
        }
        // Sharpest discontinuity across the whole motion, kept for every
        // kind so an export can show a strike that was filed as practice.
        var peakJerk = 0.0
        if lastMovingIdx > e.startIdx {
            for i in (e.startIdx + 1)...lastMovingIdx {
                peakJerk = max(peakJerk, SwingAnalyzer.jerk(buffer, at: i))
            }
        }
        m.peakJerk = peakJerk
        m.peakRotation = e.peakRot
        m.duration = duration
        m.peakAccel = e.peakAccel
        m.effort = d.referenceRotation > 0 ? min(1.2, e.peakRot / d.referenceRotation) : nil
        m.startedFromAddress = e.startedFromAddress
        if e.impact != nil {
            m.strikeScore = e.impactScore
        } else {
            let spike = SwingAnalyzer.bestSpike(buffer, from: e.searchStartIdx, to: lastMovingIdx)
            // Same line a strike is scored on: prominence over the local
            // texture, then size against the discipline threshold.
            m.strikeScore = SwingAnalyzer.strikeScore(jerk: spike.jerk, baseline: spike.jerk / max(spike.prominence, 0.001),
                                                      threshold: d.wristImpactThreshold, clipped: false)
        }
        m.clipped = e.clipped || m.clipped

        return Swing(struck: kind == .strike, kind: kind, routine: sig,
                     armConfidence: confidence, metrics: m, normalizedTrace: trace)
    }
}
