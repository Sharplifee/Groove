import Foundation

// Replays a diagnostic capture bundle (exported from Setup → "Export
// diagnostic capture") through the real RoutineDetector and prints what the
// engine decided, frame-accurate, next to what the watch decided live.
// Usage: Tools/replay-capture.sh path/to/groove-capture-*.json
//
// The point: the engine is pure shared code, so a range session replayed here
// is the same session the wrist saw. Every disagreement between the live
// events and the replay verdicts is a logic change that happened between the
// two builds — visible, attributable, and testable.

final class ReplayRecorder: RoutineDetectorDelegate {
    var swings: [(t: TimeInterval, swing: Swing)] = []
    var lastT: TimeInterval = 0
    var discards = 0
    func detectorDidArm(confidence: Double, routine: Bool) {}
    func detectorDidDisarm() {}
    func detectorDidFireTakeaway(confidence: Double) {}
    func detectorDidCompleteSwing(_ swing: Swing, wasArmed: Bool) {
        swings.append((lastT, swing))
    }
    func detectorDidDiscardMotion(reason: String, wasArmed: Bool) {
        if reason != "early restore" { discards += 1 }
    }
}

let args = CommandLine.arguments
guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]) else {
    print("usage: replay <capture-bundle.json>"); exit(2)
}
let bundle: CaptureBundle
do { bundle = try JSONDecoder().decode(CaptureBundle.self, from: data) }
catch { print("cannot decode bundle: \(error)"); exit(2) }

guard let watch = bundle.watch else { print("bundle has no watch stream"); exit(2) }
let frames = CaptureRecorder.frames(of: watch)
let discipline = Discipline(rawValue: watch.discipline) ?? .fullSwing
print("capture: \(frames.count) frames, \(String(format: "%.1f", (frames.last?.t ?? 0) - (frames.first?.t ?? 0))) s, discipline \(discipline.rawValue)")
print("live events recorded on the wrist: \(watch.events.count)")

let det = RoutineDetector()
// Reproduce the wrist's actual arming, not this machine's empty defaults: if
// the capture carried the template and config it was recorded with, install
// them. Struck/rehearsal verdicts never needed this; arm/takeaway/duck did,
// so before this every replay under-reported arming and looked like a
// regression that wasn't one.
det.discipline = discipline
if let tj = watch.templateJSON,
   let t = try? JSONDecoder().decode(RoutineTemplate.self, from: tj) {
    det.installTemplate(t)
}
if let cj = watch.configJSON,
   let c = try? JSONDecoder().decode(Config.self, from: cj) {
    det.config = c
}
let rec = ReplayRecorder()
det.delegate = rec
det.discipline = discipline
det.reset()
var narration: [(TimeInterval, String)] = []
det.onTrace = { t, label in narration.append((t, label)) }
for f in frames { rec.lastT = f.t; det.ingest(f) }

let struck = rec.swings.filter { $0.swing.resolvedKind == .strike }
let practice = rec.swings.filter { $0.swing.resolvedKind == .practice }
let waggles = rec.swings.filter { $0.swing.resolvedKind == .waggle }
print("\nREPLAY VERDICTS: \(struck.count) struck, \(practice.count) practice swings, \(waggles.count) waggles, \(rec.discards) motions ignored")
for (t, s) in rec.swings {
    let m = s.metrics
    switch s.resolvedKind {
    case .strike:
        print(String(format: "  %7.2fs  STRUCK   %-5@ tempo %.2f  back %.2fs  down %.2fs  peak %.1f rad/s  score %.2f",
                     t, m.effortLabel?.label ?? "-", m.tempoRatio, m.backswing, m.downswing, m.peakRotation, m.strikeScore ?? 0))
    case .practice:
        print(String(format: "  %7.2fs  practice %-5@ tempo %.2f  peak %.1f rad/s  jerk %.0f  score %.2f",
                     t, m.effortLabel?.label ?? "-", m.tempoRatio, m.peakRotation, m.peakJerk ?? 0, m.strikeScore ?? 0))
    case .waggle:
        print(String(format: "  %7.2fs  waggle   peak %.1f rad/s  %.2fs", t, m.peakRotation, m.duration ?? 0))
    }
}

// Side-by-side with what the wrist decided live.
let liveStruck = watch.events.filter { $0.label.contains("STRUCK") }.count
let liveReh = watch.events.filter { ($0.label.contains("rehearsal") || $0.label.contains("— practice")) && $0.label.contains("complete") }.count
print("\nLIVE ON THE WRIST: \(liveStruck) struck, \(liveReh) practice swings")
if liveStruck != struck.count || liveReh != practice.count {
    print("DISAGREEMENT — the engine now reads this session differently than the build that recorded it.")
}

if args.contains("--narrate") {
    print("\nENGINE NARRATION:")
    for (t, l) in narration { print(String(format: "  %7.2fs  %@", t, l)) }
}
