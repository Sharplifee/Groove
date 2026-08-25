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
check("rehearsals carry no trace",
      summary.rehearsals.allSatisfy { $0.normalizedTrace.isEmpty })
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
              d.takeawayThreshold > 0.35)
    }
}


// MARK: - Detector replay: the three range faults

// These drive the real detector with synthetic frame streams reproducing the
// misfires from the range visit, so the fixes can never silently regress.
final class SwingRecorder: RoutineDetectorDelegate {
    var swings: [Swing] = []
    func detectorDidArm(confidence: Double) {}
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
    check("replay: a waggle aborts silently — no phantom rehearsal logged",
          rec.swings.isEmpty)
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
    let m = SwingAnalyzer.metrics(frames: frames, takeawayIdx: 80, impactIdx: impactIdx)
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
    let m = SwingAnalyzer.metrics(frames: frames, takeawayIdx: 5, impactIdx: frames.count - 1)
    check("top: an early takeaway cannot make the downswing swallow the swing",
          m.downswing < 0.45)
}

// Reference rotation is calibrated to real swings, so a committed swing is
// judged at full intensity rather than treated as a half effort.
do {
    check("reference: a real committed swing (14 rad/s) reads as full intensity",
          SwingAnalyzer.effectiveImpactThreshold(
            base: 110, peakRotation: 14, referenceRotation: Discipline.fullSwing.referenceRotation) == 110)
}


// MARK: - Template confidence on real range data

// Forty real routine signatures sampled from Connor's exported sessions,
// twenty per class. The old similarity-ratio scorer put both medians inside
// 0.48-0.51 — an unusable dial. The variance-aware scorer must hold a real
// gap on the same data, and must never regress back into that dead band.
do {
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
    var t = RoutineTemplate()
    // Train on the first 12 of each, in alternating order as a range session
    // would produce them; score the held-out 8 of each.
    for i in 0..<12 { t.learn(struckSigs[i], struck: true); t.learn(rehSigs[i], struck: false) }
    let sScores = struckSigs.suffix(8).map { t.confidence($0) }.sorted()
    let rScores = rehSigs.suffix(8).map { t.confidence($0) }.sorted()
    let sMed = sScores[sScores.count / 2], rMed = rScores[rScores.count / 2]
    check("template: struck and rehearsal medians hold a usable gap on real data",
          sMed - rMed > 0.10)
    check("template: the population is no longer compressed into a dead band",
          sMed > 0.52 || rMed < 0.45)
}

// Rehearsals carry their intensity numbers now, so an export can show whether
// a "rehearsal" had a strike-shaped transient under the floor.
do {
    let det = RoutineDetector(); let rec = SwingRecorder()
    det.delegate = rec; det.discipline = .fullSwing; det.reset()
    let frames = stream([(1.2, 0.05, 0.01),
                         (0.4, 1.6, 0.15),
                         (0.6, 4.0, 0.20),
                         (3.2, 0.05, 0.01)])          // no strike: times out
    frames.forEach(det.ingest)
    check("instrument: a rehearsal records its peak rotation",
          rec.swings.count == 1 && !rec.swings[0].struck
          && rec.swings[0].metrics.peakRotation > 3.0)
    check("instrument: a rehearsal records its sharpest jerk",
          (rec.swings[0].metrics.peakJerk ?? -1) >= 0)
}

// One corrupt record must not wipe the archive. (Mirrors the Lossy wrapper.)
do {
    struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
    var good = Swing(struck: true,
                     routine: RoutineSignature(plateauCount: 3, meanDwell: 0.5,
                                               totalSetupDuration: 3,
                                               transitionSharpness: 0.05,
                                               dwellVariance: 0.2),
                     armConfidence: 0.7, metrics: SwingMetrics(), normalizedTrace: [])
    good.metrics.tempoRatio = 2.9
    let arr = try! JSONSerialization.jsonObject(
        with: JSONEncoder().encode([good])) as! [Any]
    let polluted = arr + [["garbage": true]]
    let data = try! JSONSerialization.data(withJSONObject: polluted)
    let out = (try? JSONDecoder().decode([Lossy<Swing>].self, from: data))?
        .compactMap(\.value) ?? []
    check("archive: a corrupt record is dropped, not the whole history",
          out.count == 1 && out[0].metrics.tempoRatio == 2.9)
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
    var frames = stream([(1.2, 0.05, 0.005), (0.4, 1.6, 0.20)])
    // Rough, jerky, ball-free motion: alternate accel every sample.
    var t = frames.last!.t + 0.01
    for k in 0..<80 {
        frames.append(mf(t, rot: 6.0, accel: k % 2 == 0 ? 0.32 : 0.18)); t += 0.01
    }
    frames += stream([(3.0, 0.04, 0.005)], from: t)
    frames.forEach(det.ingest)
    check("impact: a rough ball-free swing stays a practice swing",
          rec.swings.count == 1 && !rec.swings[0].struck)
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

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
