import Foundation
import AVFoundation
import CoreMotion
import WatchConnectivity
import UIKit

@MainActor
final class PhoneController: NSObject, ObservableObject {

    @Published var config = Config.load() {
        didSet {
            config.save()
            // The watch detector depends on handedness, wrist, and sensitivity.
            // UserDefaults don't cross devices, so this push is the only way
            // those settings ever reach it.
            ConfigSync.push(config)
        }
    }
    @Published var swings: [Swing] = []
    @Published var isSessionLive = false
    /// Kept because the paired-device host will need it, and because `status`
    /// reads from it. Not shown on the Range tab — that screen is deliberately
    /// not a live surface.
    @Published var audioState: AudioState = .full
    @Published var nowPlaying = "—"
    @Published var status = "Ready"

    enum AudioState: String { case full = "full volume", ducked = "ducked · mic open" }

    let permissions = Permissions()

    /// Demo mode shows generated swings on every screen so the layout can be
    /// seen populated without hitting balls. Held in memory only. No longer
    /// reachable from the UI — kept because the #Previews in DemoData depend on it.
    @Published var isDemoMode = false
    var realSwingsBackup: [Swing]?

    /// Appearance. Phone-local and deliberately outside `Config`, so changing it
    /// never pushes a new application context to the watch. See Theme.swift.
    @Published var theme: Theme = .stored {
        didSet {
            Palette.theme = theme
            Theme.store(theme)
        }
    }

    /// Preview/demo constructor — no WCSession, no audio, no motion.
    static func preview(swings: [Swing]) -> PhoneController {
        let c = PhoneController(previewing: true)
        c.swings = swings
        c.config.hasOnboarded = true
        c.config.hasCalibrated = true
        return c
    }

    func refreshMicPermission() { permissions.refresh() }
    func requestMicrophone() async { await permissions.requestAll() }
    func openSettings() { permissions.openSettings() }

    var summary: SessionSummary { SessionSummary(swings: swings) }

    /// Live read on how separable this player's shots are from their rehearsals.
    /// Shown during calibration so the detector proves itself before it's trusted.
    var calibrationResult: CalibrationResult? {
        // Scoped to the current calibration attempt. Counting all-time swings
        // made "Teach it again" complete instantly against stale data.
        let since = config.calibrationStartedAt ?? .distantPast
        let scoped = SessionSummary(swings: swings.filter { $0.date >= since })
        let real = scoped.struckSwings, reh = scoped.rehearsals
        guard !real.isEmpty || !reh.isEmpty else { return nil }
        let mr = real.isEmpty ? 0 : real.map(\.armConfidence).reduce(0, +) / Double(real.count)
        let mh = reh.isEmpty ? 0 : reh.map(\.armConfidence).reduce(0, +) / Double(reh.count)
        return CalibrationResult(realCount: real.count, rehearsalCount: reh.count,
                                 meanRealConfidence: mr, meanRehearsalConfidence: mh)
    }

    private let audio = LocalAudioHost()
    private let motion = CMMotionManager()
    private let store = SwingStore()
    private var pelvis: [MotionFrame] = []
    private var t0 = Date()

    private var disarmWork: DispatchWorkItem?
    /// Sequencing measured at impact, waiting for its swing to arrive.
    private var pendingPelvisLead: Double?
    private var pendingPelvisAt: Date?

    /// Last deleted swing, so a mis-tap is recoverable.
    @Published var recentlyDeleted: Swing?

    var sessions: [RangeSession] { RangeSession.group(swings) }

    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated; return q
    }()

    override convenience init() { self.init(previewing: false) }

    init(previewing: Bool) {
        super.init()
        guard !previewing else { return }
        swings = store.load()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var inputName: String { audio.currentInputName }
    var measuredLatency: TimeInterval { audio.inputLatency }
    var routeUnavailable: Bool { audio.routeUnavailable(config.route) }
    var backgroundAudioAlive: Bool { audio.isAlive }

    /// Opens a fresh calibration window so results measure the new reps only.
    func beginCalibration() {
        config.calibrationStartedAt = Date()
        config.hasCalibrated = false
        config.hasOnboarded = false
    }

    func finishCalibration(accepted: Bool) {
        config.hasCalibrated = accepted
        config.hasOnboarded = true
    }

    // MARK: Session

    /// Called only in response to the watch. There is no phone-side start —
    /// the phone is in a back pocket and can't be a control surface.
    fileprivate func mirrorSessionStart() {
        guard !isSessionLive else { return }
        t0 = Date()
        pelvis.removeAll(keepingCapacity: true)

        // This must come first. Without a live audio session the app is
        // suspended within seconds of the screen locking, which stops
        // CoreMotion and stops watch messages arriving — the duck would work
        // once and never again.
        do { try audio.startSession() }
        catch { status = "Couldn't hold the session open: \(error.localizedDescription)" }

        startPelvisCapture()
        UIApplication.shared.isIdleTimerDisabled = true
        isSessionLive = true
        status = "Session live on your watch"
    }

    fileprivate func mirrorSessionEnd() {
        motion.stopDeviceMotionUpdates()
        disarmWork?.cancel()
        audio.disarm()
        audio.endSession()          // the only place the session deactivates
        UIApplication.shared.isIdleTimerDisabled = false
        isSessionLive = false
        audioState = .full
        status = "Session ended"
    }

    /// Pelvis proxy from the back pocket. Orientation is calibrated at every
    /// address hold because a pocketed phone never sits the same way twice.
    private func startPelvisCapture() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / SwingAnalyzer.fs
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let f = MotionFrame(
                t: Date().timeIntervalSince(self.t0),
                accel: SIMD3(dm.userAcceleration.x, dm.userAcceleration.y, dm.userAcceleration.z),
                rotation: SIMD3(dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z),
                gravity: SIMD3(dm.gravity.x, dm.gravity.y, dm.gravity.z))
            Task { @MainActor in
                self.pelvis.append(f)
                let cap = Int(SwingAnalyzer.fs * 15)
                if self.pelvis.count > cap { self.pelvis.removeFirst(self.pelvis.count - cap) }
            }
        }
    }

    // MARK: Watch events

    private func handle(event: String, confidence: Double) {
        switch event {
        case "arm":
            // Open the record session early so takeaway only has to raise a fader.
            disarmWork?.cancel()
            do { try audio.arm(preferring: config.route) }
            catch { status = "Couldn't open the mic: \(error.localizedDescription)" }

        case "takeaway":
            audio.duckAndPassthrough()
            audioState = .ducked

        case "impact":
            audio.restore(afterTail: config.tailSeconds)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(config.tailSeconds))
                audioState = .full
            }
            // Snapshot sequencing NOW. Swings arrive over transferUserInfo,
            // which can lag minutes behind a 15 s pelvis buffer — by then the
            // window is gone or belongs to a different swing entirely.
            pendingPelvisLead = pelvisLeadMs()
            pendingPelvisAt = Date()

            // Tear the record session down once the tail is done. Leaving it open
            // pins Bluetooth earbuds to HFP — mono, 8-16 kHz — for the rest of
            // the session, which is exactly what scoping it was meant to avoid.
            scheduleDisarm(after: config.tailSeconds + 0.6)

        case "restore":
            // Rehearsal. Correct fast rather than predict well.
            audio.restore(afterTail: 0)
            audioState = .full
            scheduleDisarm(after: 0.6)

        case "disarm":
            audio.restore(afterTail: 0)
            audioState = .full
            // Drops to the keepalive tier only — never deactivates the session,
            // or the app dies in the pocket.
            audio.disarm()

        case "sessionStart":
            mirrorSessionStart()

        case "sessionEnd":
            mirrorSessionEnd()

        default: break
        }
    }

    /// Deferred so a quick second shot re-arms instead of thrashing the session.
    private func scheduleDisarm(after delay: TimeInterval) {
        disarmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.audio.disarm() }
        disarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ingest(swing: Swing) {
        // The spool retries until acknowledged, so duplicates are expected.
        guard !swings.contains(where: { $0.id == swing.id }) else { return }
        var swing = swing
        // Pelvis sequencing is the one metric a single sensor cannot produce.
        // Attach the snapshot taken at impact, and only if it plausibly belongs
        // to this swing rather than an older one.
        if swing.struck, let lead = pendingPelvisLead, let at = pendingPelvisAt,
           abs(at.timeIntervalSince(swing.date)) < 20 {
            swing.metrics.pelvisLeadMs = lead
        }
        pendingPelvisLead = nil
        pendingPelvisAt = nil
        swings.insert(swing, at: 0)
        persist()
    }

    /// Milliseconds by which pelvis angular velocity peaked before the wrist.
    /// Positive is correct sequencing. Both streams are anchored on the impact
    /// transient, so no cross-device clock sync is required.
    private func pelvisLeadMs() -> Double? {
        guard config.pocket != .none else { return nil }
        guard pelvis.count > Int(SwingAnalyzer.fs) else { return nil }
        guard let impact = SwingAnalyzer.impactIndex(
                pelvis, threshold: SwingAnalyzer.pelvisImpactThreshold) else { return nil }
        let lo = max(0, impact - Int(1.2 * SwingAnalyzer.fs))
        let window = Array(pelvis[lo..<impact])
        guard let peak = window.enumerated().max(by: {
            $0.element.rotationMagnitude < $1.element.rotationMagnitude
        }) else { return nil }
        return Double(window.count - peak.offset) / SwingAnalyzer.fs * 1000
    }

    /// Soft delete with a window to undo — one tap shouldn't cost a rep permanently.
    /// Writes the full swing history to a file for the share sheet. Raw traces
    /// included — there was no way to get data out of the app at all before this.
    func exportURL() -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(swings) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("groove-swings-\(stamp).json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Guards every write path — generated swings must never reach the store or
    /// they'd contaminate a real baseline.
    private func persist() {
        guard !isDemoMode else { return }
        store.save(swings)
    }

    func delete(_ swing: Swing) {
        recentlyDeleted = swing
        swings.removeAll { $0.id == swing.id }
        persist()
    }

    func undoDelete() {
        guard let s = recentlyDeleted else { return }
        swings.insert(s, at: 0)
        swings.sort { $0.date > $1.date }
        persist()
        recentlyDeleted = nil
    }

    func clearUndo() { recentlyDeleted = nil }
}

// MARK: - WCSession

extension PhoneController: WCSessionDelegate {
    nonisolated func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState,
                             error: Error?) {
        guard st == .activated else { return }
        // Seed the watch immediately — it may have launched before we did.
        Task { @MainActor in ConfigSync.push(self.config) }
    }
    nonisolated func sessionDidBecomeInactive(_ s: WCSession) {}
    nonisolated func sessionDidDeactivate(_ s: WCSession) { s.activate() }

    nonisolated func session(_ s: WCSession, didReceiveMessage message: [String: Any]) {
        route(message)
    }

    nonisolated func session(_ s: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        route(userInfo)
    }

    private nonisolated func route(_ payload: [String: Any]) {
        if let data = payload["swing"] as? Data,
           let swing = try? JSONDecoder().decode(Swing.self, from: data) {
            Task { @MainActor in self.ingest(swing: swing) }
            // Tell the watch it can drop this from its spool. Without the ack
            // the watch would resend forever.
            if let id = payload["swingID"] as? String, WCSession.default.isReachable {
                WCSession.default.sendMessage(["ack": id], replyHandler: nil, errorHandler: nil)
            }
            return
        }
        guard let event = payload["event"] as? String else { return }
        let confidence = payload["confidence"] as? Double ?? 0
        Task { @MainActor in
            // Late-join safety net: if we somehow missed sessionStart, a live
            // arm event still brings the phone up.
            if !self.isSessionLive, event == "arm" || event == "takeaway" {
                self.mirrorSessionStart()
            }
            self.handle(event: event, confidence: confidence)
        }
    }
}

// MARK: - Persistence

struct SwingStore {
    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("swings.json")
    }
    func load() -> [Swing] {
        guard let d = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode([Swing].self, from: d) else { return [] }
        return s
    }
    func save(_ swings: [Swing]) {
        guard let d = try? JSONEncoder().encode(swings) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
