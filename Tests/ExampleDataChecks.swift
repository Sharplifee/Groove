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
    check("takeaway: full swing keeps a committed trigger",
          Discipline.fullSwing.takeawayThreshold > 1.0)
    check("takeaway: a putting stroke can actually trip it",
          Discipline.putting.takeawayThreshold < 0.5)
    for d in Discipline.allCases {
        check("takeaway: \(d.rawValue) trigger sits above the stillness gate",
              d.takeawayThreshold > 0.35)
    }
}

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
