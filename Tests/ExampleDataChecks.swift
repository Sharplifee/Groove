import Foundation

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}
var failures = 0

// ---- The example session a fresh install opens on ----
let example = DemoData.exampleSwings()
let sessions = RangeSession.group(example)
let summary  = SessionSummary(swings: example)

// The example covers all three disciplines, so anything comparing numbers
// across sessions has to compare like with like. A putting stroke repeats far
// tighter than a full swing by nature; mixing them makes every metric lie.
let full = summary.filtered(to: .fullSwing)

check("example is not empty", !example.isEmpty, "\(example.count) swings")
check("example spans several sessions", sessions.count == 10, "\(sessions.count) sessions")
check("all four disciplines are present",
      summary.disciplinesPresent.count == 4,
      summary.disciplinesPresent.map(\.label).joined(separator: ", "))
check("no session mixes disciplines",
      sessions.allSatisfy { s in
          Set(s.swings.map(\.metrics.discipline)).count == 1 })
check("every session has struck swings", sessions.allSatisfy { $0.struckCount > 0 })
check("every session has rehearsals",
      sessions.allSatisfy { $0.swings.count > $0.struckCount })
check("sessions sort newest first",
      zip(sessions, sessions.dropFirst()).allSatisfy { $0.date > $1.date })

// Numbers a golfer would believe
let tempo = full.meanTempo
check("mean tempo is plausible", tempo > 2.2 && tempo < 4.2,
      String(format: "%.2f : 1", tempo))
let rep = full.repeatability
check("repeatability is plausible", rep > 0.5 && rep < 25,
      String(format: "%.1f%%", rep))
check("repeatability verdict is not the empty case",
      full.repeatabilityVerdict != "Not enough strokes yet.",
      full.repeatabilityVerdict)

// New in this rebuild
check("full swing reports pelvis lead", full.meanPelvisLead != nil,
      full.meanPelvisLead.map { String(format: "%.0f ms", $0) } ?? "nil")
check("putting reports no pelvis lead",
      summary.filtered(to: .putting).meanPelvisLead == nil,
      "hips don't move enough in a putt to measure")

// Each discipline's tempo must sit near its own reference, not the full swing's
for d in Discipline.allCases {
    let t = summary.filtered(to: d).meanTempo
    check("\(d.label) tempo near its reference",
          abs(t - d.tempoReference) < 0.6,
          String(format: "%.2f vs %.2f", t, d.tempoReference))
}

// Putting must repeat tighter than a full swing, or the scaling is wrong
// The engine's floor is a full wedge, not a driver. If this ever rises toward
// driver energy, every shorter iron drops through it and stops being recorded.
check("full-swing threshold is set at the wedge floor",
      Discipline.fullSwing.wristImpactThreshold <= 120,
      "\(Discipline.fullSwing.wristImpactThreshold) — a full PW must clear it")
check("pitching sits between chipping and putting",
      Discipline.chipping.wristImpactThreshold > Discipline.pitching.wristImpactThreshold
      && Discipline.pitching.wristImpactThreshold > Discipline.putting.wristImpactThreshold,
      "\(Discipline.pitching.wristImpactThreshold)")
check("only the full swing can reach the sensor's limit",
      Discipline.allCases.filter(\.canSaturateSensor) == [.fullSwing])
check("putting repeats tighter than full swing",
      summary.filtered(to: .putting).repeatability < full.repeatability,
      String(format: "%.2f vs %.2f",
             summary.filtered(to: .putting).repeatability, full.repeatability))

// Thresholds must descend with strike energy or quiet strokes never register
check("impact thresholds descend by strike energy",
      zip(Discipline.allCases, Discipline.allCases.dropFirst())
        .allSatisfy { $0.wristImpactThreshold > $1.wristImpactThreshold })
check("trace windows shorten with the stroke",
      zip(Discipline.allCases, Discipline.allCases.dropFirst())
        .allSatisfy { $0.tracePre >= $1.tracePre })
check("only the full swing ducks audio",
      Discipline.fullSwing.ducksAudio && Discipline.chipping.ducksAudio
      && !Discipline.putting.ducksAudio)

// Traces must be aligned and equal length or the ensemble chart lies
let traces = full.struckSwings.map(\.normalizedTrace)
check("every struck swing carries a trace", traces.allSatisfy { !$0.isEmpty })
check("all traces are the same length",
      Set(traces.map(\.count)).count == 1, "len \(traces.first?.count ?? 0)")
check("trace length matches the analyzer",
      traces.first?.count == SwingAnalyzer.traceLength)
check("practice swings carry a trace of their own; waggles carry none",
      summary.rehearsals.allSatisfy { $0.normalizedTrace.count == SwingAnalyzer.traceLength }
      && summary.waggles.allSatisfy { $0.normalizedTrace.isEmpty })
check("the example has waggles, and they never count as practice swings",
      !summary.waggles.isEmpty && summary.waggles.allSatisfy { !summary.rehearsals.contains($0) })
check("example practice swings carry a tempo near the real ones, slightly slower",
      full.meanPracticeTempo > full.meanTempo && full.meanPracticeTempo - full.meanTempo < 0.6,
      String(format: "practice %.2f vs real %.2f", full.meanPracticeTempo, full.meanTempo))
check("example full-swing session shows more than one effort band",
      full.effortMix.count > 1, "\(full.effortMix.map { "\($0.1) \($0.0.label)" })")
check("traces are the same length across disciplines",
      Set(summary.struckSwings.map(\.normalizedTrace.count)).count == 1,
      "so an ensemble never mixes window lengths")

// Impact should land where the chart draws its impact line
if let t = traces.first {
    let ix = Int(Double(t.count) * SwingAnalyzer.tracePre
                 / (SwingAnalyzer.tracePre + SwingAnalyzer.tracePost))
    let peakIdx = t.enumerated().max(by: { $0.element < $1.element })!.offset
    check("trace peaks at the impact line", abs(peakIdx - ix) < t.count / 12,
          "peak \(peakIdx), line \(ix), of \(t.count)")
}

// Ensemble must produce a usable band
let e = SwingAnalyzer.ensemble(traces)
check("ensemble median is full length", e.median.count == traces.first?.count)
check("ensemble band is ordered low <= high",
      zip(e.low, e.high).allSatisfy { $0 <= $1 })

// Self-labelling: struck swings must score higher than rehearsals, or
// calibration can never separate them
let realConf = full.struckSwings.map(\.armConfidence)
let rehConf  = full.rehearsals.map(\.armConfidence)
let mr = realConf.reduce(0,+)/Double(realConf.count)
let mh = rehConf.reduce(0,+)/Double(rehConf.count)
check("real swings score above rehearsals", mr > mh,
      String(format: "%.2f vs %.2f", mr, mh))
let cal = CalibrationResult(realCount: full.struckSwings.count,
                           rehearsalCount: full.rehearsals.count,
                           meanRealConfidence: mr, meanRehearsalConfidence: mh)
check("example separation reads as ready", cal.isReady, cal.verdict)

// Determinism — the example must not change shape between launches
check("generator is deterministic",
      DemoData.exampleSwings().map(\.metrics.tempoRatio)
        == example.map(\.metrics.tempoRatio))

// Config: the lead-wrist derivation drives the detector
check("right-handed + left wrist = lead",
      Config(handedness: .right, watchWrist: .left).watchIsLeadWrist)
check("left-handed + left wrist = trail",
      !Config(handedness: .left, watchWrist: .left).watchIsLeadWrist)

// Sensitivity ordering must be monotonic or the Setup picker lies
check("sensitivity thresholds ascend",
      Sensitivity.eager.threshold < Sensitivity.balanced.threshold
      && Sensitivity.balanced.threshold < Sensitivity.strict.threshold)

// Round-trip, because swings persist as JSON
let enc = JSONEncoder(); let dec = JSONDecoder()
let rt = try! dec.decode([Swing].self, from: try! enc.encode(example))
check("swings survive a JSON round trip", rt.count == example.count)
check("round trip preserves discipline",
      rt.map(\.metrics.discipline) == example.map(\.metrics.discipline))
check("round trip preserves traces",
      rt.first(where: { $0.struck })?.normalizedTrace
        == example.first(where: { $0.struck })?.normalizedTrace)

// ---- The trend card must have a story, not scatter ----
// Per discipline, exactly as Today plots it. Mixing them here would compare a
// putting session against a full-swing session and mean nothing.
let byAge = RangeSession.group(example)
    .filter { $0.summary.discipline == .fullSwing }
    .sorted { $0.date < $1.date }
let curve = byAge.map { $0.summary.repeatability }
check("trend has enough points to draw", curve.count >= 3, "\(curve.count)")
check("trend spans a visible range", (curve.max()! - curve.min()!) > 2.0,
      String(format: "spread %.2f", curve.max()! - curve.min()!))
// Direction, not extremes. Requiring the oldest session to be the single
// loosest forbids an off day worse than where the player started, which is a
// real and common shape. What the card has to communicate is that things are
// improving and that the latest session is the best one.
let half = curve.count / 2
let early = curve.prefix(half).reduce(0,+) / Double(half)
let late  = curve.suffix(half).reduce(0,+) / Double(half)
check("trend improves overall", early > late,
      String(format: "early %.2f → late %.2f", early, late))
check("newest session is the tightest", curve.last! == curve.min()!,
      String(format: "%.2f newest", curve.last!))
check("trend is not a straight line",
      !zip(curve, curve.dropFirst()).allSatisfy { $0 > $1 },
      "has at least one off session, as a real run of form does")

// Previews must still get a plain history with no forced arc
check("default history still produces sessions",
      RangeSession.group(DemoData.history()).count == 3)
check("oneSession preview is a single session",
      RangeSession.group(DemoData.oneSession).count == 1)

print("")


// MARK: - Groove Score

// The anchors are the contract; these pin them where the verdict copy lives.
check("score: perfect repeatability maps to 100",
      GrooveScore.repeatability(0) == 100)
check("score: the 'where you want to be' line (5%) maps to 75",
      abs(GrooveScore.repeatability(5) - 75) < 0.001)
check("score: the 'a bit loose' boundary (8%) maps to 50",
      abs(GrooveScore.repeatability(8) - 50) < 0.001)
check("score: beyond the last anchor clamps to zero",
      GrooveScore.repeatability(40) == 0)
check("score: hips and hands together is already under half",
      GrooveScore.sequencing(0) < 50)
check("score: a 30ms hip lead scores high",
      GrooveScore.sequencing(30) > 85)

// Discipline fairness: the same normalised spread must earn the same
// repeatability score whether it came from the range or the green.
do {
    func session(_ d: Discipline, cv: Double) -> SessionSummary {
        // Three tempos around the discipline reference with the requested CV.
        let m = d.tempoReference
        let sd = cv / 100 * m
        let tempos = [m - sd, m, m + sd]
        let swings = tempos.map { t -> Swing in
            var mm = SwingMetrics(); mm.discipline = d; mm.tempoRatio = t; mm.smoothness = 80
            return Swing(struck: true, routine: RoutineSignature(plateauCount: 3, meanDwell: 0.8, totalSetupDuration: 4, transitionSharpness: 0.5, dwellVariance: 0.1),
                         armConfidence: 1, metrics: mm, normalizedTrace: [0, 1, 0])
        }
        return SessionSummary(swings: swings)
    }
    let full = session(.fullSwing, cv: 4.0)   // normalised 4.0 on scale 1.0
    let putt = session(.putting,  cv: 2.0)    // normalised 4.0 on scale 0.5
    let a = full.repeatabilityScore ?? -1
    let b = putt.repeatabilityScore ?? -2
    check("score: equal normalised spread scores equally across disciplines",
          abs(a - b) < 0.75)
    check("score: a full-swing session at 4% CV lands in Grooved territory",
          (full.grooveScore ?? 0) >= 70)
}

// Under three struck strokes there is no score, and the app never invents one.
do {
    var m = SwingMetrics(); m.tempoRatio = 3.0; m.smoothness = 80
    let two = SessionSummary(swings: (0..<2).map { _ in
        Swing(struck: true, routine: RoutineSignature(plateauCount: 3, meanDwell: 0.8, totalSetupDuration: 4, transitionSharpness: 0.5, dwellVariance: 0.1),
              armConfidence: 1, metrics: m, normalizedTrace: [0, 1, 0]) })
    check("score: two strokes is not enough for a score", two.grooveScore == nil)
}

// The example data must show believable scores — the first-launch screen is a
// sales floor, and a demo session scoring 12 or 100 would read as broken.
do {
    let sessions = RangeSession.group(DemoData.history())
    let scores = sessions.compactMap { $0.summary.grooveScore }
    check("score: every demo session earns a score", scores.count == sessions.count)
    check("score: demo scores live in a believable band",
          scores.allSatisfy { $0 >= 35 && $0 <= 95 })
}


// MARK: - Placement sensing

// A phone parked by the ball must not pass for a phone in a pocket, even when
// the strike's ground shock puts one violent transient into the window.
do {
    func frame(_ t: Double, rot: Double, accel: Double = 0.01) -> MotionFrame {
        MotionFrame(t: t, accel: SIMD3(accel, 0, 0),
                    rotation: SIMD3(rot, 0, 0), gravity: SIMD3(0, -1, 0))
    }
    // On body: sustained hip rotation through the downswing.
    let pocket = (0..<120).map { frame(Double($0) / 100, rot: 0.6 + 0.4 * sin(Double($0) / 8)) }
    check("placement: a pocketed phone reads as on-body",
          SwingAnalyzer.isOnBody(pocket))

    // Parked: near-stillness with one ground-shock spike near the end.
    let parked = (0..<120).map { i in
        frame(Double(i) / 100, rot: i == 110 ? 9.0 : 0.02, accel: i == 110 ? 3.0 : 0.005)
    }
    check("placement: a phone parked by the ball reads as off-body",
          !SwingAnalyzer.isOnBody(parked))
    check("placement: the ground-shock spike alone cannot flip the verdict",
          !SwingAnalyzer.isOnBody(parked.map {
              MotionFrame(t: $0.t, accel: $0.accel, rotation: $0.rotation * 2, gravity: $0.gravity) }))

    // Too little data refuses to vouch for anything.
    check("placement: a near-empty window never claims on-body",
          !SwingAnalyzer.isOnBody(Array(pocket.prefix(5))))
}


// MARK: - Intensity-scaled strike floor

// The warm-up problem, pinned: a half-intensity swing with a real (softer)
// strike must be caught; a smooth rehearsal at the same softness must not.
do {
    let d = Discipline.fullSwing
    let full = SwingAnalyzer.effectiveImpactThreshold(
        base: d.wristImpactThreshold, peakRotation: d.referenceRotation,
        referenceRotation: d.referenceRotation)
    check("floor: a committed swing keeps the calibrated threshold",
          abs(full - d.wristImpactThreshold) < 0.001)

    let half = SwingAnalyzer.effectiveImpactThreshold(
        base: d.wristImpactThreshold, peakRotation: d.referenceRotation * 0.5,
        referenceRotation: d.referenceRotation)
    check("floor: half intensity halves the threshold", abs(half - 55) < 0.001)

    let lazy = SwingAnalyzer.effectiveImpactThreshold(
        base: d.wristImpactThreshold, peakRotation: 1.0,
        referenceRotation: d.referenceRotation)
    check("floor: the floor never drops below 35% of base",
          abs(lazy - d.wristImpactThreshold * 0.35) < 0.001)

    // A warm-up strike around jerk 60 was invisible to the fixed 110 floor
    // and is caught at half intensity now.
    check("floor: the warm-up strike the range visit exposed is now caught",
          60 > half && 60 < d.wristImpactThreshold)
    // A smooth practice swing's jerk stays under even the lowest floor.
    check("floor: a smooth rehearsal stays below the minimum floor",
          25 < d.wristImpactThreshold * 0.35 + 15 && 25 < half)
}

// Takeaway scales with the discipline: the short game is visible now, and
// idle wrist noise still can't start a swing.
do {
    // 1.0 rad/s: early enough to catch an unhurried takeaway from its first
    // move (the old 1.2 fired mid-backswing on smooth players), still nearly
    // three times the stillness gate so idle wrist noise can't start a swing.
    check("takeaway: full swing keeps a committed trigger",
          Discipline.fullSwing.takeawayThreshold >= 0.95)
    check("takeaway: a putting stroke can actually trip it",
          Discipline.putting.takeawayThreshold < 0.5)
    for d in Discipline.allCases {
        check("takeaway: \(d.rawValue) trigger sits above the stillness gate",
              d.takeawayThreshold > RoutineDetector.stillnessRotation)
    }
    // The floor is 1.2x the stillness gate, not "nearly three times" as
    // DECISIONS 39 claimed. Pin the real ratio so the note and the code agree.
    check("takeaway: putting floor is 1.2x the stillness gate",
          abs(Discipline.putting.takeawayThreshold
              / RoutineDetector.stillnessRotation - 1.2) < 0.01)
    do {
    }
}


// MARK: - Detector replay: the three range faults

// These drive the real detector with synthetic frame streams reproducing the
// misfires from the range visit, so the fixes can never silently regress.
final class SwingRecorder: RoutineDetectorDelegate {
    var swings: [Swing] = []
    func detectorDidArm(confidence: Double, routine: Bool) {}
    func detectorDidDisarm() {}
    func detectorDidFireTakeaway(confidence: Double) {}
    func detectorDidCompleteSwing(_ swing: Swing, wasArmed: Bool) { swings.append(swing) }
}

func mf(_ t: Double, rot: Double, accel: Double) -> MotionFrame {
    MotionFrame(t: t, accel: SIMD3(accel, 0, 0),
                rotation: SIMD3(rot, 0, 0), gravity: SIMD3(0, -1, 0))
}

/// Builds a stream at 100 Hz from (duration, rotation, accel) segments.
func stream(_ segs: [(Double, Double, Double)], from t0: Double = 0) -> [MotionFrame] {
    var out: [MotionFrame] = []; var t = t0
    for (dur, rot, acc) in segs {
        for _ in 0..<Int(dur * 100) { out.append(mf(t, rot: rot, accel: acc)); t += 0.01 }
    }
    return out
}

/// Deterministic noise in 0..<1.
func noise(_ seed: Int, _ i: Int) -> Double {
    let x = sin(Double(seed) * 12.9898 + Double(i) * 78.233) * 43758.5453
    return x - x.rounded(.down)
}

/// A swing-shaped motion at 100 Hz: backswing lobe to ~40% of peak, a quiet
/// top, a downswing ramping to `peak` rad/s, an optional strike sample, then a
/// decaying finish. Accel follows rotation (centripetal, ~0.02 g per (rad/s)²)
/// with optional per-sample texture. This is the shape every classification
/// check runs against — flat plateaus are not swings and the engine says so.
func swingShape(peak: Double, back: Double = 0.75, top: Double = 0.10, down: Double = 0.28,
                finish: Double = 0.7, strike strikeAccel: Double? = nil, texture: Double = 0,
                from t0: Double, seed: Int = 1) -> [MotionFrame] {
    var out: [MotionFrame] = []; var t = t0; var i = 0
    func push(_ rot: Double, _ extra: Double = 0) {
        let base = 0.02 * rot * rot
        let tex = texture * (noise(seed, i) - 0.5) * 2
        out.append(mf(t, rot: max(0, rot), accel: max(0.002, base + tex + extra)))
        t += 0.01; i += 1
    }
    let nb = Int(back * 100), nt = Int(top * 100), nd = Int(down * 100), nf = Int(finish * 100)
    for k in 0..<nb { push(0.4 * peak * sin(Double(k) / Double(nb) * .pi) + 0.3) }
    // The pause at the top IS the rotation minimum — the club has stopped —
    // and the downswing builds from it.
    for _ in 0..<nt { push(0.3) }
    for k in 0..<nd { let u = Double(k + 1) / Double(nd); push(0.3 + (peak - 0.3) * u * u) }
    if let s = strikeAccel { push(peak * 0.9, s) }
    // The finish decays continuously from the peak — a ball-free swing has no
    // discontinuity anywhere, which is the whole point of the practice checks.
    for k in 0..<nf { let u = Double(k + 1) / Double(nf); push(peak * exp(-u * 4.5)) }
    return out
}

// Fault 1: a slow warm-up swing whose impact lands ~2.3s after takeaway. The
// old code let the 3s timeout keep running after the strike was found and
// logged it as a rehearsal once the trace tail pushed past the limit.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var frames = stream([(1.2, 0.05, 0.01),      // settle
                         (0.4, 1.6, 0.15),       // slow takeaway
                         (1.4, 1.0, 0.20),       // long lazy backswing
                         (0.2, 0.30, 0.15),      // transition pause (after 0.7s window)
                         (0.3, 14.0, 0.30)])     // downswing builds speed
    // The strike: one violent accel discontinuity.
    let ti = frames.last!.t
    frames += [mf(ti + 0.01, rot: 10, accel: 1.6)]
    frames += stream([(1.0, 2.0, 0.25), (0.8, 0.05, 0.01)], from: ti + 0.02)
    frames.forEach(det.ingest)
    check("replay: the slow warm-up strike completes as struck, not rehearsal",
          rec.swings.count == 1 && rec.swings[0].struck)
}

// Fault 2: a waggle at address sustains takeaway rotation then dies. The old
// code entered a swing, timed out, logged a phantom rehearsal, and sat in
// recovery while the REAL swing that followed went unseen.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    let frames = stream([(1.2, 0.05, 0.01),
                         (0.12, 1.8, 0.20),      // the waggle
                         (1.5, 0.10, 0.02)])     // back to address stillness
    frames.forEach(det.ingest)
    check("replay: a waggle is filed as a waggle, never as a practice swing",
          rec.swings.count == 1 && rec.swings[0].resolvedKind == .waggle
          && !rec.swings[0].struck)
}

// Fault 3: recovery released by time, not only stillness — a fidgety wrist
// between balls must not leave the detector blind to the next swing.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    func swing(from t: Double) -> [MotionFrame] {
        var f = stream([(0.4, 1.6, 0.15), (0.5, 6.0, 0.25)], from: t)
        let ti = f.last!.t
        f += [mf(ti + 0.01, rot: 8, accel: 1.5)]
        f += stream([(1.0, 2.0, 0.25)], from: ti + 0.02)
        return f
    }
    var frames = stream([(1.2, 0.05, 0.01)])
    frames += swing(from: frames.last!.t + 0.01)
    frames += stream([(3.0, 0.6, 0.10)], from: frames.last!.t + 0.01)  // fidget, never still
    frames += swing(from: frames.last!.t + 0.01)
    frames += stream([(1.0, 0.05, 0.01)], from: frames.last!.t + 0.01)
    frames.forEach(det.ingest)
    check("replay: fidgeting between balls cannot blind the detector",
          rec.swings.filter(\.struck).count == 2)
}


// MARK: - Diagnostic capture round trip

// A capture must survive serialisation and come back as the same frames —
// otherwise replay analyses a different session than the one that happened.
do {
    let rec = CaptureRecorder(device: "watch", discipline: .fullSwing)
    let frames = stream([(0.3, 1.2, 0.2)])
    frames.forEach(rec.append)
    rec.mark(0.15, "takeaway (armed=false)")
    let data = try! rec.data()
    let back = try! JSONDecoder().decode(CaptureStream.self, from: data)
    let replayed = CaptureRecorder.frames(of: back)
    check("capture: frames survive the round trip", replayed.count == frames.count)
    check("capture: values survive the round trip",
          replayed.first!.rotationMagnitude == frames.first!.rotationMagnitude
          && replayed.last!.t == frames.last!.t)
    check("capture: events ride along", back.events == [.init(t: 0.15, label: "takeaway (armed=false)")])
    check("capture: the column contract is stamped in the file",
          back.columns == CaptureColumns.count && back.version == CaptureColumns.version)
}

// The whole point: a captured stream replays through the real detector and
// produces the same verdicts as the live session did.
do {
    let rec = CaptureRecorder(device: "watch", discipline: .fullSwing)
    var frames = stream([(1.2, 0.05, 0.01), (0.4, 1.6, 0.15), (0.5, 6.0, 0.25)])
    let ti = frames.last!.t
    frames += [mf(ti + 0.01, rot: 8, accel: 1.5)]
    frames += stream([(1.0, 2.0, 0.25), (0.8, 0.05, 0.01)], from: ti + 0.02)
    frames.forEach(rec.append)
    let back = try! JSONDecoder().decode(CaptureStream.self, from: rec.data())

    let det = RoutineDetector(); let out = SwingRecorder()
    det.delegate = out; det.discipline = .fullSwing; det.reset()
    var narration: [String] = []
    det.onTrace = { _, label in narration.append(label) }
    CaptureRecorder.frames(of: back).forEach(det.ingest)
    check("capture: a serialised session replays to the same struck verdict",
          out.swings.count == 1 && out.swings[0].struck)
    check("capture: the detector narrates its decisions during replay",
          narration.contains { $0.hasPrefix("takeaway") }
          && narration.contains { $0.hasPrefix("impact found") }
          && narration.contains { $0.contains("STRUCK") })
}


// MARK: - Top of backswing

// A synthetic swing with a known top: quiet address, backswing, a clear pause,
// then a ramp to impact. The old global-minimum rule put the top at address on
// exactly this shape, because address is quieter than the top.
do {
    var frames: [MotionFrame] = []
    var t = 0.0
    func seg(_ dur: Double, _ rot: Double, _ acc: Double) {
        for _ in 0..<Int(dur * 100) {
            frames.append(mf(t, rot: rot, accel: acc)); t += 0.01
        }
    }
    seg(0.8, 0.02, 0.005)   // address — the quietest part of the whole window
    seg(0.7, 3.0, 0.10)     // backswing
    seg(0.12, 0.20, 0.02)   // the top
    seg(0.28, 9.0, 0.35)    // downswing
    let impactIdx = frames.count - 1
    let m = SwingAnalyzer.metrics(frames: frames, takeawayIdx: 80, impactIdx: impactIdx,
                                  discipline: .fullSwing)
    check("top: the downswing is measured from the top, not from address",
          m.downswing > 0.22 && m.downswing < 0.42)
    check("top: the backswing gets the rest of the swing",
          m.backswing > 0.55 && m.backswing < 0.95)
    check("top: tempo lands in a golfer's range rather than nonsense",
          m.tempoRatio > 1.5 && m.tempoRatio < 4.0)
}

// A swing whose takeaway fired early (forward press) — extra quiet lead-in
// must not become the "top" and swallow the whole swing into the downswing.
do {
    var frames: [MotionFrame] = []
    var t = 0.0
    func seg(_ dur: Double, _ rot: Double, _ acc: Double) {
        for _ in 0..<Int(dur * 100) { frames.append(mf(t, rot: rot, accel: acc)); t += 0.01 }
    }
    seg(1.0, 0.01, 0.002)   // long dead lead-in
    seg(0.6, 3.0, 0.10)
    seg(0.10, 0.25, 0.02)
    seg(0.30, 9.0, 0.35)
    let m = SwingAnalyzer.metrics(frames: frames, takeawayIdx: 5, impactIdx: frames.count - 1,
                                  discipline: .fullSwing)
    check("top: an early takeaway cannot make the downswing swallow the swing",
          m.downswing < 0.45)
}

// Reference rotation is calibrated to real swings, so a committed swing is
// judged at full intensity rather than treated as a half effort.
do {
    // The 14 rad/s measured in the field came from a PITCHING session logged
    // in full-swing mode, so it calibrates the short game, not the full swing.
    check("reference: a measured pitch (14 rad/s) reads as full intensity for pitching",
          SwingAnalyzer.effectiveImpactThreshold(
            base: 110, peakRotation: 14, referenceRotation: Discipline.pitching.referenceRotation) >= 100)
}


// MARK: - Template confidence on real range data

// Forty real routine signatures sampled from Connor's exported sessions,
// twenty per class, at file scope so the sensitivity checks reuse them.
let struckSigs: [RoutineSignature] = [
    RoutineSignature(plateauCount: 3, meanDwell: 0.4933, totalSetupDuration: 4.8738, transitionSharpness: 0.0566, dwellVariance: 0.3592),
    RoutineSignature(plateauCount: 5, meanDwell: 0.2800, totalSetupDuration: 6.0213, transitionSharpness: 0.1232, dwellVariance: 0.1091),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3100, totalSetupDuration: 5.4170, transitionSharpness: 0.1014, dwellVariance: 0.1246),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3625, totalSetupDuration: 1.9545, transitionSharpness: 0.0564, dwellVariance: 0.2331),
    RoutineSignature(plateauCount: 1, meanDwell: 1.2700, totalSetupDuration: 1.2700, transitionSharpness: 0.0185, dwellVariance: 0.0000),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4767, totalSetupDuration: 1.8248, transitionSharpness: 0.0710, dwellVariance: 0.1050),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4667, totalSetupDuration: 3.9208, transitionSharpness: 0.5299, dwellVariance: 0.4007),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4533, totalSetupDuration: 1.5642, transitionSharpness: 0.0087, dwellVariance: 0.1358),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3625, totalSetupDuration: 5.5758, transitionSharpness: 0.0634, dwellVariance: 0.4184),
    RoutineSignature(plateauCount: 1, meanDwell: 1.3900, totalSetupDuration: 1.3900, transitionSharpness: 0.0170, dwellVariance: 0.0000),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4567, totalSetupDuration: 3.6907, transitionSharpness: 0.0166, dwellVariance: 0.3408),
    RoutineSignature(plateauCount: 3, meanDwell: 0.3900, totalSetupDuration: 2.2565, transitionSharpness: 0.0249, dwellVariance: 0.1044),
    RoutineSignature(plateauCount: 1, meanDwell: 1.3000, totalSetupDuration: 1.3000, transitionSharpness: 0.0109, dwellVariance: 0.0000),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3225, totalSetupDuration: 2.1275, transitionSharpness: 0.0391, dwellVariance: 0.1692),
    RoutineSignature(plateauCount: 2, meanDwell: 0.6900, totalSetupDuration: 1.8352, transitionSharpness: 0.0150, dwellVariance: 0.4667),
    RoutineSignature(plateauCount: 2, meanDwell: 0.7000, totalSetupDuration: 1.9036, transitionSharpness: 0.0504, dwellVariance: 0.2970),
    RoutineSignature(plateauCount: 2, meanDwell: 0.6700, totalSetupDuration: 1.8036, transitionSharpness: 0.0429, dwellVariance: 0.0141),
    RoutineSignature(plateauCount: 1, meanDwell: 1.3800, totalSetupDuration: 1.3800, transitionSharpness: 0.2090, dwellVariance: 0.0000),
    RoutineSignature(plateauCount: 2, meanDwell: 0.6550, totalSetupDuration: 3.1092, transitionSharpness: 0.0074, dwellVariance: 0.4031),
    RoutineSignature(plateauCount: 2, meanDwell: 0.6950, totalSetupDuration: 2.3864, transitionSharpness: 0.0163, dwellVariance: 0.2616)
]
let rehSigs: [RoutineSignature] = [
    RoutineSignature(plateauCount: 3, meanDwell: 0.4767, totalSetupDuration: 2.7669, transitionSharpness: 0.0761, dwellVariance: 0.3592),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3300, totalSetupDuration: 5.2083, transitionSharpness: 0.0719, dwellVariance: 0.1288),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3075, totalSetupDuration: 4.1649, transitionSharpness: 0.0365, dwellVariance: 0.2691),
    RoutineSignature(plateauCount: 5, meanDwell: 0.2760, totalSetupDuration: 3.8622, transitionSharpness: 0.1274, dwellVariance: 0.1293),
    RoutineSignature(plateauCount: 2, meanDwell: 0.6150, totalSetupDuration: 2.6284, transitionSharpness: 0.0223, dwellVariance: 0.3465),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4900, totalSetupDuration: 2.0753, transitionSharpness: 0.2631, dwellVariance: 0.1473),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3375, totalSetupDuration: 4.4460, transitionSharpness: 0.0412, dwellVariance: 0.2056),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3425, totalSetupDuration: 5.8278, transitionSharpness: 0.1699, dwellVariance: 0.2208),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4633, totalSetupDuration: 2.8491, transitionSharpness: 0.2534, dwellVariance: 0.2272),
    RoutineSignature(plateauCount: 5, meanDwell: 0.2860, totalSetupDuration: 2.6378, transitionSharpness: 0.1766, dwellVariance: 0.1167),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4533, totalSetupDuration: 5.5476, transitionSharpness: 0.4385, dwellVariance: 0.1922),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4567, totalSetupDuration: 4.9549, transitionSharpness: 0.1631, dwellVariance: 0.1940),
    RoutineSignature(plateauCount: 2, meanDwell: 0.6800, totalSetupDuration: 1.4712, transitionSharpness: 0.0054, dwellVariance: 0.6930),
    RoutineSignature(plateauCount: 4, meanDwell: 0.3200, totalSetupDuration: 6.0211, transitionSharpness: 0.0567, dwellVariance: 0.1978),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4567, totalSetupDuration: 5.5275, transitionSharpness: 0.3375, dwellVariance: 0.0777),
    RoutineSignature(plateauCount: 5, meanDwell: 0.2980, totalSetupDuration: 4.0523, transitionSharpness: 0.0863, dwellVariance: 0.2481),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4067, totalSetupDuration: 2.2266, transitionSharpness: 0.0776, dwellVariance: 0.1665),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4400, totalSetupDuration: 1.8359, transitionSharpness: 0.0537, dwellVariance: 0.2381),
    RoutineSignature(plateauCount: 3, meanDwell: 0.4400, totalSetupDuration: 2.5676, transitionSharpness: 0.2351, dwellVariance: 0.1952),
    RoutineSignature(plateauCount: 1, meanDwell: 1.2400, totalSetupDuration: 1.2400, transitionSharpness: 0.0211, dwellVariance: 0.0000)
]

do {
    var t = RoutineTemplate()
    // Train on the first 12 of each, alternating as a range session would
    // produce them; score the held-out 8 of each.
    for i in 0..<12 { t.learn(struckSigs[i], struck: true); t.learn(rehSigs[i], struck: false) }
    let sScores = struckSigs.suffix(8).map { t.confidence($0) }.sorted()
    let rScores = rehSigs.suffix(8).map { t.confidence($0) }.sorted()
    let sMed = sScores[sScores.count / 2], rMed = rScores[rScores.count / 2]
    check("template: struck and rehearsal medians hold a usable gap on real data",
          sMed - rMed > 0.10)
    check("template: the population is no longer compressed into a dead band",
          sMed > 0.52 || rMed < 0.45)
}

// MARK: - The narrator speaks plainly and only what the data backs

func narratorSession(reps: [Double], tempos: [Double], lead: Double? = nil,
                     discipline: Discipline = .fullSwing) -> SessionSummary {
    var swings: [Swing] = []
    let n = max(reps.count, tempos.count)
    for i in 0..<n {
        let r = i < reps.count ? reps[i] : 5.0
        var m = SwingMetrics()
        m.discipline = discipline
        m.backswing = 0.7 + r / 100
        m.downswing = 0.25
        m.tempoRatio = i < tempos.count ? tempos[i] : 2.8
        m.smoothness = 70
        m.pelvisLeadMs = lead
        swings.append(Swing(struck: true,
                            routine: RoutineSignature(plateauCount: 3, meanDwell: 0.5,
                                                      totalSetupDuration: 2.5,
                                                      transitionSharpness: 0.04,
                                                      dwellVariance: 0.2),
                            armConfidence: 0.6, metrics: m, normalizedTrace: []))
    }
    return SessionSummary(swings: swings)
}

do {
    // A quickening session: tempo falls from ~3.0 to ~2.4 over twelve swings.
    let tempos = [3.0, 3.0, 2.95, 2.9, 2.85, 2.8, 2.7, 2.6, 2.5, 2.45, 2.4, 2.4]
    let s = narratorSession(reps: Array(repeating: 5.0, count: 12), tempos: tempos)
    let line = s.narrative(previous: nil)
    check("narrator: a quickening session gets named as one",
          line.contains("quicker"))
    check("narrator: never more than two sentences",
          line.filter { $0 == "." }.count <= 3 && line.count < 260)
}

do {
    // Hands-first sequencing is the one thing worth saying. Tempos vary a
    // little (a score requires real spread) but not enough to be the story.
    let s = narratorSession(reps: [],
                            tempos: [2.9, 2.95, 2.85, 2.9, 2.92, 2.88], lead: -8)
    check("narrator: hands-before-hips becomes the coaching line",
          s.narrative(previous: nil).contains("hips"))
}

do {
    // Quickening over the ball: real swings at ~2.5, practice at ~3.0, with
    // enough spread to earn a score. The narrator must name it.
    var s = narratorSession(reps: [], tempos: [2.4, 2.6, 2.5, 2.45, 2.55, 2.5])
    for t in [3.0, 3.05, 2.95] {
        var m = SwingMetrics(); m.discipline = .fullSwing; m.tempoRatio = t
        s.swings.append(Swing(struck: false, kind: .practice,
                              routine: RoutineSignature(plateauCount: 1, meanDwell: 0.3, totalSetupDuration: 0.3, transitionSharpness: 0.02, dwellVariance: 0),
                              armConfidence: 0.3, metrics: m, normalizedTrace: []))
    }
    check("narrator: quickening over the ball against practice swings gets said",
          s.narrative(previous: nil).contains("quicken over the ball"))
}

do {
    // Too few strokes: the narrator says so instead of inventing a story.
    let s = narratorSession(reps: [5.0, 5.0], tempos: [2.9, 2.9])
    check("narrator: with too little data it says exactly that",
          s.narrative(previous: nil).lowercased().contains("not enough"))
}

do {
    // A genuinely tighter session than last time says so. Spread is the
    // repeatability number, so the fixtures carry it directly: the earlier
    // session wobbles ±0.35 around tempo 2.9, the newer one ±0.08.
    let prev = narratorSession(reps: [],
                               tempos: [2.55, 3.25, 2.6, 3.2, 2.65, 3.15, 2.7, 3.1])
    let now = narratorSession(reps: [],
                              tempos: [2.82, 2.98, 2.84, 2.96, 2.86, 2.94, 2.88, 2.92])
    check("narrator: real improvement over last session gets said",
          now.narrative(previous: prev).contains("tighter than last time"))
}


// MARK: - Impact detection reads the swing as it truly is

// A smooth swinger's damped strike: the spike is well under the absolute
// floor that a hard swing would need, but stands far above this swing's own
// buttery texture. The old detector filed exactly this as a practice swing.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var frames = stream([(1.2, 0.05, 0.005),
                         (0.4, 1.4, 0.06),       // gentle takeaway
                         (0.6, 5.0, 0.08),       // smooth, low-jerk swing
                         (0.25, 9.0, 0.10)])     // quiet downswing
    let ti = frames.last!.t
    frames += [mf(ti + 0.01, rot: 7, accel: 0.62)]   // damped strike: modest spike
    frames += stream([(0.9, 1.5, 0.09), (0.9, 0.04, 0.005)], from: ti + 0.02)
    frames.forEach(det.ingest)
    check("impact: a damped strike on a smooth swing is read as struck",
          rec.swings.count == 1 && rec.swings[0].struck)
}

// A vigorous practice swing with plenty of rough motion but no discontinuity
// must stay a practice swing — its jerks never stand out from its own texture.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var frames = stream([(1.2, 0.05, 0.005)])
    // Rough, jerky, ball-free motion: heavy per-sample texture, no spike.
    frames += swingShape(peak: 12, texture: 0.07, from: frames.last!.t + 0.01, seed: 7)
    frames += stream([(3.0, 0.04, 0.005)], from: frames.last!.t + 0.01)
    frames.forEach(det.ingest)
    check("impact: a rough ball-free swing stays a practice swing",
          rec.swings.count == 1 && !rec.swings[0].struck
          && rec.swings[0].resolvedKind == .practice)
}

// A sharp clunk at low rotation — grounding the club mid-window — is not a
// strike, however big the spike.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var frames = stream([(1.2, 0.05, 0.005),
                         (0.4, 1.5, 0.10),
                         (0.5, 4.0, 0.10),
                         (0.4, 0.08, 0.02)])     // club comes to rest
    let ti = frames.last!.t
    frames += [mf(ti + 0.01, rot: 0.1, accel: 1.8)]  // huge clunk, near-zero rotation
    frames += stream([(2.6, 0.05, 0.005)], from: ti + 0.02)
    frames.forEach(det.ingest)
    check("impact: a clunk at rest is not a strike",
          rec.swings.count == 1 && !rec.swings[0].struck)
}


// MARK: - Sensitivity thresholds live where the scorer actually scores

// The thresholds must straddle the real distribution: train on the same real
// fixtures, and balanced has to sit between the two class medians — above
// where practice swings score, below where real strikes score. If the scorer
// moves again, this fails until the dial is recalibrated with it.
do {
    var t = RoutineTemplate()
    for i in 0..<12 { t.learn(struckSigs[i], struck: true); t.learn(rehSigs[i], struck: false) }
    let sMed = struckSigs.suffix(8).map { t.confidence($0) }.sorted()[4]
    let rMed = rehSigs.suffix(8).map { t.confidence($0) }.sorted()[4]
    let bal = Sensitivity.balanced.threshold
    check("sensitivity: balanced sits between the class medians", rMed < bal && bal < sMed)
    check("sensitivity: the dial is ordered and sane",
          Sensitivity.eager.threshold < bal && bal < Sensitivity.strict.threshold
          && Sensitivity.eager.threshold > 0.25 && Sensitivity.strict.threshold < 0.65)
}


// MARK: - Early strikes keep their trace

// A strike inside the first second of a session must still produce a
// full-length, impact-aligned trace instead of dropping out of the overlay.
do {
    var frames = stream([(0.5, 0.05, 0.01), (0.3, 8.0, 0.30)])
    let impactIdx = frames.count
    frames += [mf(frames.last!.t + 0.01, rot: 6, accel: 1.4)]
    frames += stream([(0.6, 1.0, 0.10)], from: frames.last!.t + 0.01)
    let trace = SwingAnalyzer.normalizedTrace(frames: frames, impactIdx: impactIdx)
    check("trace: an early strike still gets a full-length trace",
          trace.count == SwingAnalyzer.traceLength)
    // Impact lands at the same normalised position as any other trace.
    let expected = Int(Double(SwingAnalyzer.traceLength)
                       * Discipline.fullSwing.tracePre
                       / (Discipline.fullSwing.tracePre + Discipline.fullSwing.tracePost))
    let peakAt = trace.indices.max { trace[$0] < trace[$1] } ?? -1
    check("trace: the early strike's impact sits where every other impact sits",
          abs(peakAt - expected) <= 2)
}



// MARK: - Audit fixes (2026-09-01)

// 1.1 — sequencing is hip-lead MINUS hand-lead, so a hands-first swing must be
// able to read NEGATIVE. The old code reported hip-peak-to-impact alone, which
// is positive on every swing. Build a metric with a late hip and an early hand
// and confirm the reported lead goes negative.
do {
    var m = SwingMetrics()
    m.discipline = .fullSwing
    m.wristPeakLeadMs = 300          // hands peaked 300 ms before impact
    // Simulate the phone's contribution: hips only 120 ms before impact.
    let hipLead = 120.0
    let reported = hipLead - m.wristPeakLeadMs!
    check("sequencing: hands-first swing reports a negative lead", reported < 0)
    // And hips-first reads positive.
    m.wristPeakLeadMs = 90
    check("sequencing: hips-first swing reports a positive lead", 120.0 - m.wristPeakLeadMs! > 0)
}

// 1.4/1.5 — backswing timing runs on frame timestamps and a true takeaway, so a
// swing whose trigger fired late still reports a full backswing. Feed a swing
// with a slow rotation ramp that crosses the 1.0 trigger only well into the
// backswing, and confirm the measured backswing is longer than trigger-to-top.
do {
    var frames: [MotionFrame] = []
    var t = 0.0
    func seg(_ dur: Double, _ rot: Double, _ acc: Double) {
        for _ in 0..<Int(dur * 100) { frames.append(mf(t, rot: rot, accel: acc)); t += 0.01 }
    }
    seg(1.0, 0.05, 0.005)          // address, still
    seg(0.3, 0.6, 0.02)            // club creeping back UNDER the 1.0 trigger
    seg(0.3, 3.0, 0.05)            // trigger crosses here, mid-backswing
    let topT = t
    seg(0.05, 0.1, 0.01)           // top
    seg(0.25, 9.0, 0.10)           // downswing
    let ti = t
    frames.append(mf(t, rot: 7, accel: 1.4)); t += 0.01   // strike
    seg(0.6, 1.0, 0.05)
    let trigger = Int(1.3 * 100)   // where isTakeaway would fire (~1.3 s in)
    let impactIdx = Int(ti * 100)
    let m = SwingAnalyzer.metrics(frames: frames, takeawayIdx: trigger, impactIdx: impactIdx,
                                  discipline: .fullSwing)
    // True takeaway walks back to the still address, so the backswing includes
    // the creep the trigger missed — strictly longer than trigger→top.
    let triggerToTop = topT - Double(trigger) / 100
    check("timing: backswing is measured from the true start, not the late trigger",
          m.backswing > triggerToTop)
    check("timing: tempo ratio stays in a golfer's range with true-start timing",
          m.tempoRatio > 1.2 && m.tempoRatio < 6.0)
}

// 1.6/1.7 — a wrist-cock spike early in the backswing must NOT be taken as
// impact when the real, sharper strike follows. The confirmation step should
// pick the strike, not the cock.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var frames = stream([(1.2, 0.05, 0.005), (0.4, 1.6, 0.06)])
    let cockT = frames.last!.t
    frames += [mf(cockT + 0.01, rot: 4, accel: 0.30)]        // wrist-cock: modest spike
    frames += stream([(0.5, 5.0, 0.08), (0.25, 9.0, 0.10)], from: cockT + 0.02)
    let ti = frames.last!.t
    frames += [mf(ti + 0.01, rot: 8, accel: 1.6)]            // real strike: sharper
    frames += stream([(0.9, 1.2, 0.06), (0.6, 0.04, 0.005)], from: ti + 0.02)
    frames.forEach(det.ingest)
    check("impact: the real strike wins over an earlier wrist-cock spike",
          rec.swings.count == 1 && rec.swings[0].struck
          && rec.swings[0].metrics.downswing < 0.6)   // downswing timed from the true top, not the cock
}

// 1.10 — smoothness is discipline-normalised: the same synthetic buttery motion
// scored as a putt and as a full swing must land close, not 20 points apart.
do {
    func swing(_ dur: Double) -> [MotionFrame] {
        var f: [MotionFrame] = []; var t = 0.0
        let n = Int(dur * 100)
        for i in 0..<n {
            let x = Double(i) / Double(n)
            f.append(mf(t, rot: 6 * sin(x * .pi), accel: 0.1 + 0.05 * sin(x * .pi))); t += 0.01
        }
        return f
    }
    let full = SwingAnalyzer.metricsSmoothnessProbe(swing(1.1), discipline: .fullSwing)
    let putt = SwingAnalyzer.metricsSmoothnessProbe(swing(0.4), discipline: .putting)
    check("smoothness: the same motion scores comparably across disciplines",
          abs(full - putt) < 15)
}


// MARK: - Pitching reference eases the floor for a soft pitch

// The bug in the field: pitching reference was 22*0.28 = 6.2 rad/s, but real
// pitches peak near 13.5, so peakRotation/reference always exceeded 1 and the
// floor never dropped — soft contact went unheard. With the measured
// reference, a gentle pitch (well under committed) must ease the floor below
// the committed floor, not sit at or above it.
do {
    let committed = 13.5, soft = 7.0
    let ref = Discipline.pitching.referenceRotation
    let base = Discipline.pitching.wristImpactThreshold
    let floorSoft = SwingAnalyzer.effectiveImpactThreshold(
        base: base, peakRotation: soft, referenceRotation: ref)
    let floorCommitted = SwingAnalyzer.effectiveImpactThreshold(
        base: base, peakRotation: committed, referenceRotation: ref)
    check("pitch: a soft pitch eases the floor below a committed one",
          floorSoft < floorCommitted)
    check("pitch: the committed floor is not inflated past the base",
          floorCommitted <= base + 0.001)
}


// MARK: - A simulated range session through the whole engine (2026-10-27)

// No field capture exists yet, so this is the next best thing: a scripted
// bucket of balls with everything that actually happens at a range — walking
// to the next ball, raking one over, teeing up, waggles, practice swings at
// three efforts, strikes at four — pushed through the real engine. Every
// motion class the old engine got wrong is pinned here. When a real capture
// lands it replaces nothing; it adds to this.

enum Range {
    static func still(_ secs: Double, from t0: Double, seed: Int) -> [MotionFrame] {
        (0..<Int(secs * 100)).map { i in
            mf(t0 + Double(i) / 100,
               rot: 0.04 + 0.08 * noise(seed, i),
               accel: 0.005 + 0.02 * noise(seed + 1, i))
        }
    }
    /// Strides at 1.8 Hz: the wrist swings 0.7–4.3 rad/s, one lobe per step.
    static func walk(_ secs: Double, from t0: Double, seed: Int) -> [MotionFrame] {
        (0..<Int(secs * 100)).map { i in
            let t = Double(i) / 100
            let s = sin(2 * .pi * 1.8 * t)
            return mf(t0 + t, rot: 2.5 + 1.8 * s + 0.2 * noise(seed, i),
                      accel: 0.22 + 0.18 * abs(s) + 0.04 * noise(seed + 1, i))
        }
    }
    /// One pull of the club to drag a ball over: a single soft lobe.
    static func rake(from t0: Double, seed: Int) -> [MotionFrame] {
        (0..<80).map { i in
            let u = Double(i) / 80
            let r = 3.0 * sin(u * .pi)
            return mf(t0 + Double(i) / 100, rot: r + 0.1 * noise(seed, i), accel: 0.02 * r * r + 0.01)
        }
    }
    /// Bending to tee a ball: three similar lobes with short gaps.
    static func teeUp(from t0: Double, seed: Int) -> [MotionFrame] {
        var out: [MotionFrame] = []; var t = t0; var i = 0
        for peak in [3.5, 4.6, 3.2] {
            for k in 0..<60 { let r = peak * sin(Double(k) / 60 * .pi); out.append(mf(t, rot: r + 0.1 * noise(seed, i), accel: 0.02 * r * r + 0.01)); t += 0.01; i += 1 }
            for _ in 0..<20 { out.append(mf(t, rot: 0.8 + 0.2 * noise(seed, i), accel: 0.03)); t += 0.01; i += 1 }
        }
        return out
    }
    /// A waggle at address: brief, above the takeaway trigger, well under swing speed.
    static func waggle(from t0: Double, seed: Int) -> [MotionFrame] {
        (0..<35).map { i in
            let r = 2.5 * sin(Double(i) / 35 * .pi)
            return mf(t0 + Double(i) / 100, rot: r + 0.05 * noise(seed, i), accel: 0.02 * r * r + 0.01)
        }
    }
    static func practice(effort: Double, from t0: Double, seed: Int) -> [MotionFrame] {
        swingShape(peak: 22 * effort, texture: 0.02, from: t0, seed: seed)
    }
    static func strike(effort: Double, from t0: Double, seed: Int) -> [MotionFrame] {
        swingShape(peak: 22 * effort, strike: 0.6 + 2.5 * effort, texture: 0.02, from: t0, seed: seed)
    }
}

final class RangeRecorder: RoutineDetectorDelegate {
    var swings: [Swing] = []
    var takeaways = 0, restores = 0, discards = 0, arms = 0
    func detectorDidArm(confidence: Double, routine: Bool) { arms += 1 }
    func detectorDidDisarm() {}
    func detectorDidFireTakeaway(confidence: Double) { takeaways += 1 }
    func detectorDidCompleteSwing(_ swing: Swing, wasArmed: Bool) {
        swings.append(swing)
        if wasArmed && !swing.struck { restores += 1 }
    }
    func detectorDidDiscardMotion(reason: String, wasArmed: Bool) {
        if reason != "early restore" { discards += 1 }
        if wasArmed { restores += 1 }
    }
}

do {
    let det = RoutineDetector(); let rec = RangeRecorder()
    var cfg = Config(); cfg.duckMode = .everySwing; cfg.gateUntilFirstImpact = false
    det.config = cfg
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var narration: [String] = []
    det.onTrace = { _, l in narration.append(l) }

    var f: [MotionFrame] = []
    var seed = 100
    func add(_ make: (Double, Int) -> [MotionFrame]) {
        let t0 = (f.last?.t ?? -0.01) + 0.01
        f += make(t0, seed); seed += 7
    }
    add { Range.still(2.0, from: $0, seed: $1) }
    add { Range.walk(4.0, from: $0, seed: $1) }          // to the bay
    add { Range.still(1.5, from: $0, seed: $1) }
    add { Range.waggle(from: $0, seed: $1) }
    add { Range.still(0.8, from: $0, seed: $1) }
    add { Range.practice(effort: 0.9, from: $0, seed: $1) }
    add { Range.still(1.0, from: $0, seed: $1) }
    add { Range.waggle(from: $0, seed: $1) }
    add { Range.still(1.2, from: $0, seed: $1) }
    add { Range.strike(effort: 0.9, from: $0, seed: $1) }  // full
    add { Range.still(0.5, from: $0, seed: $1) }
    add { Range.walk(2.0, from: $0, seed: $1) }
    add { Range.rake(from: $0, seed: $1) }
    add { Range.walk(1.0, from: $0, seed: $1) }
    add { Range.still(1.0, from: $0, seed: $1) }
    add { Range.practice(effort: 0.5, from: $0, seed: $1) }
    add { Range.still(1.0, from: $0, seed: $1) }
    add { Range.strike(effort: 0.5, from: $0, seed: $1) }  // half
    add { Range.still(1.0, from: $0, seed: $1) }
    add { Range.practice(effort: 0.3, from: $0, seed: $1) } // one-handed feel swing
    add { Range.still(1.0, from: $0, seed: $1) }
    add { Range.strike(effort: 0.3, from: $0, seed: $1) }  // soft
    add { Range.still(1.0, from: $0, seed: $1) }
    add { Range.teeUp(from: $0, seed: $1) }
    add { Range.still(1.0, from: $0, seed: $1) }
    add { Range.strike(effort: 1.0, from: $0, seed: $1) }  // driver-ish
    add { Range.still(2.0, from: $0, seed: $1) }
    f.forEach(det.ingest)

    let strikes = rec.swings.filter { $0.resolvedKind == .strike }
    let practice = rec.swings.filter { $0.resolvedKind == .practice }
    let waggles = rec.swings.filter { $0.resolvedKind == .waggle }
    check("range: every struck ball is a strike — full, half, soft and all-out",
          strikes.count == 4, "\(strikes.count) of 4")
    check("range: every practice swing is a practice swing — including the one-handed feel swing",
          practice.count == 3, "\(practice.count) of 3")
    check("range: both waggles are waggles, not practice swings",
          waggles.count == 2, "\(waggles.count) of 2")
    // The walk–rake–walk run never goes quiet, so it is one motion, not three.
    check("range: walking, raking and teeing up are not swings of any kind",
          rec.discards == 3, "\(rec.discards) motions ignored (walk; walk-rake-walk; tee-up)")
    check("range: nothing walked between balls was logged",
          rec.swings.count == 9, "\(rec.swings.count) logged")
    check("range: strikes carry an effort band each",
          Set(strikes.compactMap(\.metrics.effortLabel)).count >= 3,
          strikes.compactMap { $0.metrics.effortLabel?.label }.joined(separator: " "))
    check("range: the soft strike reads as easy and the all-out one as full",
          strikes.first?.metrics.effortLabel == .full && strikes[2].metrics.effortLabel == .easy
          && strikes.last?.metrics.effortLabel == .full)
    check("range: practice swings carry a tempo of their own",
          practice.allSatisfy { $0.metrics.tempoRatio > 1.5 && $0.metrics.tempoRatio < 5 },
          practice.map { String(format: "%.2f", $0.metrics.tempoRatio) }.joined(separator: " "))
    check("range: practice swings carry a trace aligned on their speed peak",
          practice.allSatisfy { $0.normalizedTrace.count == SwingAnalyzer.traceLength })
    check("range: strike tempos sit in a golfer's band",
          strikes.allSatisfy { $0.metrics.tempoRatio > 1.8 && $0.metrics.tempoRatio < 4.5 },
          strikes.map { String(format: "%.2f", $0.metrics.tempoRatio) }.joined(separator: " "))
    check("range: every logged motion knows whether it started from address",
          rec.swings.allSatisfy { $0.metrics.startedFromAddress == true })
    check("range: strikes score higher on the strike line than practice swings",
          (strikes.map { $0.metrics.strikeScore ?? 0 }.min() ?? 0)
          > (practice.map { $0.metrics.strikeScore ?? 0 }.max() ?? 1))
    check("range: every swing records its duration and peak acceleration",
          rec.swings.filter { $0.resolvedKind != .waggle }
              .allSatisfy { ($0.metrics.duration ?? 0) > 0.5 && ($0.metrics.peakAccel ?? 0) > 0 })
    check("range: in every-swing mode the music dropped for each swing from address and nothing else",
          rec.takeaways == 7 + 1, "\(rec.takeaways) takeaways (7 swings from address + the first walk off a standstill)")
    check("range: the duck on the walk was released before the walk ended",
          narration.contains { $0.contains("striding, not swinging") })
    check("range: every ducked motion with no ball restored the audio",
          rec.restores >= 4, "\(rec.restores) restores")
    let summary = SessionSummary(swings: rec.swings)
    check("range: the session summary separates practice swings from waggles",
          summary.rehearsals.count == 3 && summary.waggles.count == 2)
    check("range: the practice-vs-real tempo shift is reported once both have three reps",
          summary.tempoShiftOverBall != nil)
    check("range: the effort mix lists the bands that occurred",
          summary.effortMix.map(\.1).reduce(0, +) == 4, "\(summary.effortMix)")
}

// The same bucket in routine-only mode: nothing ducks until the routine model
// is trained and calibrated, but every swing is still logged — capture and
// arming stay independent.
do {
    let det = RoutineDetector(); let rec = RangeRecorder()
    var cfg = Config(); cfg.duckMode = .routineOnly; cfg.hasCalibrated = false
    det.config = cfg
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var f: [MotionFrame] = []
    func add(_ make: (Double, Int) -> [MotionFrame], _ seed: Int) {
        let t0 = (f.last?.t ?? -0.01) + 0.01; f += make(t0, seed)
    }
    add({ Range.still(1.5, from: $0, seed: $1) }, 3)
    add({ Range.practice(effort: 0.8, from: $0, seed: $1) }, 4)
    add({ Range.still(1.2, from: $0, seed: $1) }, 5)
    add({ Range.strike(effort: 0.8, from: $0, seed: $1) }, 6)
    add({ Range.still(1.5, from: $0, seed: $1) }, 7)
    f.forEach(det.ingest)
    check("routine-only: untaught, the music is never touched",
          rec.takeaways == 0 && rec.arms == 0)
    check("routine-only: untaught, every swing is still logged",
          rec.swings.count == 2 && rec.swings[1].struck)
}

// Putting through the same engine: a slow, low stroke must register as a
// stroke at all (the old fixed takeaway never saw one), with a strike.
do {
    let det = RoutineDetector(); let rec = RangeRecorder()
    var cfg = Config(); cfg.duckMode = .everySwing
    det.config = cfg
    det.delegate = rec; det.discipline = .putting; det.reset()
    var f = Range.still(1.5, from: 0, seed: 11)
    // Backstroke, short pause, forward stroke, tap, short follow.
    f += swingShape(peak: 2.4, back: 0.5, top: 0.08, down: 0.25, finish: 0.4,
                    strike: 0.25, texture: 0.004, from: f.last!.t + 0.01, seed: 12)
    f += Range.still(1.5, from: f.last!.t + 0.01, seed: 13)
    f += swingShape(peak: 2.2, back: 0.5, top: 0.08, down: 0.25, finish: 0.4,
                    texture: 0.004, from: f.last!.t + 0.01, seed: 14)
    f += Range.still(1.5, from: f.last!.t + 0.01, seed: 15)
    f.forEach(det.ingest)
    check("putting: a putt with the ball reads as a strike",
          rec.swings.first?.resolvedKind == .strike, "\(rec.swings.map(\.resolvedKind))")
    check("putting: a practice stroke reads as practice",
          rec.swings.count == 2 && rec.swings[1].resolvedKind == .practice)
    check("putting: the green never ducks the music", rec.takeaways == 0)
}

// Motion-level fields survive the archive and old records still decode.
do {
    var m = SwingMetrics(); m.duration = 1.4; m.effort = 0.7; m.strikeScore = 0.9
    let s = Swing(struck: true, kind: .strike, routine: RoutineSignature(plateauCount: 2, meanDwell: 0.5, totalSetupDuration: 2, transitionSharpness: 0.1, dwellVariance: 0.1), armConfidence: 0.5, metrics: m, normalizedTrace: [0, 1])
    let data = try! JSONEncoder().encode([s])
    let back = try! JSONDecoder().decode([Swing].self, from: data)
    check("archive: kind and motion fields round-trip",
          back[0].resolvedKind == .strike && back[0].metrics.effort == 0.7 && back[0].metrics.effortLabel == .threeQuarter)
    // A record from before `kind` existed: struck=false means practice.
    let legacy = """
    [{"id":"7E57E57E-0000-4000-8000-000000000001","date":0,"sessionID":"7E57E57E-0000-4000-8000-000000000002","struck":false,"routine":{"plateauCount":1,"meanDwell":0.3,"totalSetupDuration":0.3,"transitionSharpness":0.0,"dwellVariance":0.0},"armConfidence":0.4,"metrics":{"discipline":"fullSwing","backswing":0,"downswing":0,"transitionDwell":0,"tempoRatio":0,"transitionSharpness":0,"smoothness":0,"peakRotation":0,"clipped":false},"normalizedTrace":[]}]
    """
    let old = try! JSONDecoder().decode([Swing].self, from: legacy.data(using: .utf8)!)
    check("archive: a record saved before kinds existed decodes as a practice swing",
          old[0].resolvedKind == .practice && old[0].kind == nil)
    var c = Config(); c.hasOnboarded = true
    let cj = try! JSONEncoder().encode(c)
    let legacyCfg = String(data: cj, encoding: .utf8)!.replacingOccurrences(of: ",\"duckModeStored\":\"everySwing\"", with: "")
    let cc = try! JSONDecoder().decode(Config.self, from: legacyCfg.data(using: .utf8)!)
    check("config: a config saved before duck modes existed defaults to every swing",
          cc.duckMode == .everySwing)
}


// MARK: - Audit sweep 2026-10-28

final class SweepRecorder: RoutineDetectorDelegate {
    var swings: [Swing] = []
    var arms = 0, takeaways = 0, impacts = 0, disarms = 0, recovers = 0, starts = 0
    var impactLags: [TimeInterval] = []
    func detectorDidArm(confidence: Double, routine: Bool) { arms += 1 }
    func detectorDidDisarm() { disarms += 1 }
    func detectorDidFireTakeaway(confidence: Double) { takeaways += 1 }
    func detectorDidCompleteSwing(_ swing: Swing, wasArmed: Bool) { swings.append(swing) }
    func detectorDidDetectImpact(wasArmed: Bool, lag: TimeInterval) { impacts += 1; impactLags.append(lag) }
    func detectorDidRecover() { recovers += 1 }
    func detectorDidStartMotion(fromAddress: Bool) { starts += 1 }
}

// A forward press right before the takeaway — the commonest real pre-shot
// pattern — must not turn a swing from address into one "on the walk".
do {
    let det = RoutineDetector(); let rec = SweepRecorder()
    var cfg = Config(); cfg.duckMode = .everySwing
    det.config = cfg; det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var f = Range.still(2.0, from: 0, seed: 21)
    // Forward press: 0.15 s at 0.8 rad/s, 0.15 s re-still, then the swing.
    f += stream([(0.15, 0.8, 0.05), (0.15, 0.1, 0.02)], from: f.last!.t + 0.01)
    f += Range.strike(effort: 0.85, from: f.last!.t + 0.01, seed: 22)
    f += Range.still(1.5, from: f.last!.t + 0.01, seed: 23)
    f.forEach(det.ingest)
    check("sweep: a forward press before the swing keeps it a swing from address",
          rec.swings.count == 1 && rec.swings[0].struck && rec.swings[0].metrics.startedFromAddress == true,
          "\(rec.swings.map { ($0.resolvedKind, $0.metrics.startedFromAddress ?? false) })")
    check("sweep: and the music still drops for it", rec.takeaways == 1)
    check("sweep: the first ball of a session ducks in every-swing mode",
          rec.takeaways == 1 && rec.impacts == 1)
    check("sweep: the impact event carries a small positive detection lag",
          rec.impactLags.allSatisfy { $0 > 0.05 && $0 < 0.2 }, "\(rec.impactLags)")
    check("sweep: recovery hands the face back to watching", rec.recovers >= 1)
    check("sweep: every motion start is reported", rec.starts == 1)
}

// A wrist-cock step early in the backswing — a 0.4 g step at low rotation
// with the floor at its minimum — must not be confirmed as a strike, and the
// real strike that follows must be.
do {
    let det = RoutineDetector(); let rec = SweepRecorder()
    var cfg = Config(); cfg.duckMode = .everySwing
    det.config = cfg; det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var f = Range.still(1.5, from: 0, seed: 31)
    // Slow early backswing at 2.5 rad/s with a sharp 0.4 g set, then the swing.
    var t = f.last!.t + 0.01
    for k in 0..<40 {
        let step = k == 30 ? 0.45 : 0.0
        f.append(mf(t, rot: 2.5, accel: 0.12 + step)); t += 0.01
    }
    f += swingShape(peak: 19, back: 0.5, strike: 2.6, texture: 0.02, from: t, seed: 32)
    f += Range.still(1.5, from: f.last!.t + 0.01, seed: 33)
    f.forEach(det.ingest)
    check("sweep: a wrist-cock step before swing speed is not a strike",
          rec.swings.count == 1 && rec.swings[0].struck && rec.swings[0].metrics.backswing > 0.5,
          "\(rec.swings.map { ($0.resolvedKind, $0.metrics.backswing) })")
    check("sweep: only one impact event fired, at the real strike", rec.impacts == 1)
}

// Putting never opens the phone's microphone: nothing to duck, nothing to arm.
do {
    let det = RoutineDetector(); let rec = SweepRecorder()
    var cfg = Config(); cfg.duckMode = .everySwing
    det.config = cfg; det.delegate = rec; det.discipline = .putting; det.reset()
    var f = Range.still(2.0, from: 0, seed: 41)
    f += swingShape(peak: 2.4, back: 0.5, top: 0.08, down: 0.25, finish: 0.4,
                    strike: 0.25, texture: 0.004, from: f.last!.t + 0.01, seed: 42)
    f += Range.still(2.0, from: f.last!.t + 0.01, seed: 43)
    f.forEach(det.ingest)
    check("sweep: putting never arms the phone's mic", rec.arms == 0 && rec.takeaways == 0)
    check("sweep: the putt is still recorded", rec.swings.first?.struck == true)
}

// Ducking off: nothing arms, everything records.
do {
    let det = RoutineDetector(); let rec = SweepRecorder()
    var cfg = Config(); cfg.duckMode = .off
    det.config = cfg; det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var f = Range.still(2.0, from: 0, seed: 51)
    f += Range.strike(effort: 0.9, from: f.last!.t + 0.01, seed: 52)
    f += Range.still(2.0, from: f.last!.t + 0.01, seed: 53)
    f.forEach(det.ingest)
    check("sweep: ducking off arms nothing and records everything",
          rec.arms == 0 && rec.takeaways == 0 && rec.swings.count == 1 && rec.swings[0].struck)
}

// Standing still for a minute: the arm times out once and does not re-arm
// on the same stillness — the phone's audio session must not be thrashed
// every 30 s for a player who is just standing there.
do {
    let det = RoutineDetector(); let rec = SweepRecorder()
    var cfg = Config(); cfg.duckMode = .everySwing
    det.config = cfg; det.delegate = rec; det.discipline = .fullSwing; det.reset()
    Range.still(70, from: 0, seed: 61).forEach(det.ingest)
    check("sweep: standing still re-arms at most once per stillness",
          rec.arms == 1 && rec.disarms == 1, "arms \(rec.arms) disarms \(rec.disarms)")
}

// Strike duration runs to the end of the follow-through, like practice swings.
do {
    let det = RoutineDetector(); let rec = SweepRecorder()
    var cfg = Config(); cfg.duckMode = .everySwing
    det.config = cfg; det.delegate = rec; det.discipline = .fullSwing; det.reset()
    var f = Range.still(1.5, from: 0, seed: 71)
    f += Range.strike(effort: 0.8, from: f.last!.t + 0.01, seed: 72)
    f += Range.still(1.0, from: f.last!.t + 0.01, seed: 73)
    f += Range.practice(effort: 0.8, from: f.last!.t + 0.01, seed: 74)
    f += Range.still(1.5, from: f.last!.t + 0.01, seed: 75)
    f.forEach(det.ingest)
    let d = rec.swings.map { $0.metrics.duration ?? 0 }
    check("sweep: a strike and a practice swing of the same shape report the same duration",
          d.count == 2 && abs(d[0] - d[1]) < 0.15, "\(d)")
}

// Summary discipline follows every motion, not only strikes.
do {
    var m = SwingMetrics(); m.discipline = .putting; m.tempoRatio = 2.0
    let s = SessionSummary(swings: [Swing(struck: false, kind: .practice,
        routine: RoutineSignature(plateauCount: 1, meanDwell: 0.3, totalSetupDuration: 0.3, transitionSharpness: 0.02, dwellVariance: 0),
        armConfidence: 0.3, metrics: m, normalizedTrace: [])])
    check("sweep: a session of unstruck putts is still a putting session",
          s.discipline == .putting && s.disciplinesPresent == [.putting])
}

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
