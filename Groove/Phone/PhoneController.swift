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

    enum AudioState: String { case full = "full volume", ducked = "music ducked" }

    let permissions = Permissions()

    /// A worked example, shown on every screen so a new player can see what
    /// their own session will look like before they've hit anything. Held in
    /// memory only and never written to disk.
    ///
    /// This is ON by default on a fresh install and switches itself off the
    /// moment a real swing lands. Opening the app to three empty screens was
    /// the single most-repeated complaint, and a toggle buried in Setup does
    /// not fix that — a first-run default does.
    @Published var isShowingExample = false
    /// The real swings sitting behind the example, so a genuine swing arriving
    /// mid-example is never lost.
    @Published var realSwingsBackup: [Swing]?

    /// Always the count of real swings, whatever is on screen.
    var realSwingCount: Int { realSwingsBackup?.count ?? swings.count }

    /// Mirrors the discipline the watch is running, so pelvis analysis uses the
    /// matching threshold. Sent with the session-start event rather than through
    /// ConfigSync, because it changes per session rather than per setup.
    @Published var discipline: Discipline = .fullSwing

    /// iPad runs the read-only second screen instead of the tab bar.
    var isPadLayout: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Appearance. Phone-local and deliberately outside `Config`, so changing it
    /// never pushes a new application context to the watch. See Theme.swift.
    @Published var theme: Theme = .stored {
        didSet {
            Palette.theme = theme
            Theme.store(theme)
        }
    }

    /// The green header band. Separate from the palette — it used to be a third
    /// theme that differed from the second in nothing else.
    @Published var showsBand: Bool = Theme.storedBand {
        didSet {
            Palette.showsBand = showsBand
            Theme.storeBand(showsBand)
        }
    }

    /// Preview/demo constructor — no WCSession, no audio, no motion.
    static func preview(swings: [Swing]) -> PhoneController {
        let c = PhoneController(previewing: true)
        c.swings = swings
        c.isShowingExample = false
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
        // Fresh install, or a player who hasn't logged a session yet: show the
        // worked example rather than three empty screens.
        if swings.isEmpty {
            realSwingsBackup = []
            swings = DemoData.exampleSwings()
            isShowingExample = true
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var inputName: String { audio.currentInputName }
    var outputName: String { audio.currentOutputName }
    /// False means HFP has been negotiated and the player's music has just been
    /// degraded — which should now be impossible, so it is worth surfacing.
    var outputIsHighFidelity: Bool { audio.outputIsHighFidelity }
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
    /// The phone half of a diagnostic capture. Owned by `queue`, same as the
    /// pelvis buffer it records alongside.
    private var capture: CaptureRecorder?
    private var pendingWatchStream: CaptureStream?
    private var pendingPhoneStream: CaptureStream?

    fileprivate func mirrorSessionStart(capturing: Bool = false) {
        guard !isSessionLive else { return }
        t0 = Date()
        pelvis.removeAll(keepingCapacity: true)
        if capturing {
            let rec = CaptureRecorder(device: "phone", discipline: discipline)
            queue.addOperation { [self] in capture = rec }
        }

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
        queue.addOperation { [self] in
            if let rec = capture {
                pendingPhoneStream = rec.stream
                capture = nil
                tryWriteCaptureBundle()
            }
        }
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
            // Already on the serial capture queue — mutate in place. The old
            // version hopped to the main actor for every frame, which is a
            // hundred main-thread tasks a second for an entire session, spent
            // on a buffer the UI never reads. The buffer is owned by this
            // queue now; readers snapshot through it.
            self.capture?.append(f)
            self.pelvis.append(f)
            let cap = Int(SwingAnalyzer.fs * 15)
            if self.pelvis.count > cap { self.pelvis.removeFirst(self.pelvis.count - cap) }
        }
    }

    // MARK: Watch events

    private func handle(event: String, confidence: Double) {
        if capture != nil {
            let t = Date().timeIntervalSince(t0)
            queue.addOperation { [self] in capture?.mark(t, "phone received: \(event)") }
        }
        switch event {
        case "arm":
            // Open the record session early so takeaway only has to raise a fader.
            disarmWork?.cancel()
            do { try audio.arm(preferring: config.route) }
            catch { status = "Couldn't open the mic: \(error.localizedDescription)" }

        case "takeaway":
            audio.duckForTakeaway()
            audioState = .ducked

        case "impact":
            // The player has already heard the real strike through the earbud
            // seal. This is the amplified copy landing on top of ducked media.
            audio.fireImpactBurst()
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

            // Stop the rolling buffer once the tail is done. There is no HFP
            // penalty any more, so this is just housekeeping rather than the
            // load-bearing teardown it used to be.
            scheduleDisarm(after: config.tailSeconds + 0.6)

        case "restore":
            // Rehearsal. Correct fast rather than predict well.
            audio.restore(afterTail: 0)
            audioState = .full
            scheduleDisarm(after: 0.6)

        case "disarm":
            audio.restore(afterTail: 0)
            audioState = .full
            // Stops capture only — never deactivates the session, or the app
            // dies in the pocket.
            audio.disarm()

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
        guard realSwingsBackup?.contains(where: { $0.id == swing.id }) != true else { return }
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
        // Demo mode is showing generated data, so a genuine swing must go to the
        // real set behind it — appending here would put it in the fake list and
        // persist() would then refuse to write it, losing it for good. The watch
        // has already been acked by this point, so nothing else holds a copy.
        if isShowingExample {
            // A real swing has arrived, so the example has served its purpose.
            // Fold it away and show the player their own session instead.
            realSwingsBackup?.insert(swing, at: 0)
            if let real = realSwingsBackup { store.save(real) }
            setExampleMode(false)
        } else {
            swings.insert(swing, at: 0)
            persist()
        }
    }

    /// Milliseconds by which pelvis angular velocity peaked before the wrist.
    /// Positive is correct sequencing. Both streams are anchored on the impact
    /// transient, so no cross-device clock sync is required.
    private func pelvisLeadMs() -> Double? {
        guard config.pocket != .none else { return nil }
        // Only the full swing turns the hips enough for a pocket phone to read.
        guard discipline.reportsSequencing else { return nil }
        // Snapshot through the capture queue that owns the buffer.
        var buf: [MotionFrame] = []
        let op = BlockOperation { [self] in buf = pelvis }
        queue.addOperations([op], waitUntilFinished: true)
        guard buf.count > Int(SwingAnalyzer.fs) else { return nil }
        guard let impact = SwingAnalyzer.impactIndex(
                buf, threshold: discipline.pelvisImpactThreshold) else { return nil }
        let lo = max(0, impact - Int(1.2 * SwingAnalyzer.fs))
        let window = Array(buf[lo..<impact])
        // The placement setting says where the phone is SUPPOSED to be. On a
        // hot day it comes out of the pocket and gets parked by the ball or
        // under the bag, still playing music — and ground shock from a strike
        // a foot away can fake a hip transient. So the window itself is asked
        // whether it came off a body, per swing: parked, sequencing silently
        // sits out; back in the pocket, it resumes. No setting to remember.
        guard SwingAnalyzer.isOnBody(window) else { return nil }
        guard let peak = window.enumerated().max(by: {
            $0.element.rotationMagnitude < $1.element.rotationMagnitude
        }) else { return nil }
        return Double(window.count - peak.offset) / SwingAnalyzer.fs * 1000
    }

    /// Both halves land asynchronously — the phone stream at session end, the
    /// watch stream whenever transferFile completes, which can be a minute
    /// later. Whichever arrives second writes the bundle; a bundle with one
    /// half is still written after the other, so a transfer failure loses the
    /// watch's half, never the whole capture. Runs on `queue`.
    private func tryWriteCaptureBundle() {
        guard pendingWatchStream != nil || pendingPhoneStream != nil else { return }
        let bundle = CaptureBundle(watch: pendingWatchStream, phone: pendingPhoneStream)
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("groove-capture-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: url)
        if pendingWatchStream != nil && pendingPhoneStream != nil {
            pendingWatchStream = nil; pendingPhoneStream = nil
        }
    }

    /// Newest capture bundle on disk, for the share sheet.
    func captureExportURL() -> URL? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    /// Soft delete with a window to undo — one tap shouldn't cost a rep permanently.
    /// Writes the full swing history to a file for the share sheet. Raw traces
    /// included — there was no way to get data out of the app at all before this.
    func exportURL() -> URL? {
        // Never export made-up data under a filename that reads as real.
        guard !isShowingExample else { return nil }
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
        guard !isShowingExample else { return }
        store.save(swings)
    }

    /// Swaps the worked example in and out. The real swings are parked in
    /// `realSwingsBackup` while it's on, so nothing made-up can reach the store
    /// and nothing real can be lost.
    func setExampleMode(_ on: Bool) {
        guard on != isShowingExample else { return }
        if on {
            realSwingsBackup = swings
            swings = DemoData.exampleSwings()
            isShowingExample = true
        } else {
            isShowingExample = false
            swings = realSwingsBackup ?? []
            realSwingsBackup = nil
            persist()
        }
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

    nonisolated func session(_ s: WCSession, didReceive file: WCSessionFile) {
        // The system deletes the file when this returns — read it now.
        guard (file.metadata?["kind"] as? String) == "capture",
              let data = try? Data(contentsOf: file.fileURL),
              let stream = try? JSONDecoder().decode(CaptureStream.self, from: data)
        else { return }
        Task { @MainActor in
            self.queue.addOperation { [self] in
                pendingWatchStream = stream
                tryWriteCaptureBundle()
            }
        }
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
        let sentDiscipline = (payload["discipline"] as? String)
            .flatMap(Discipline.init(rawValue:))

        // `transferUserInfo` is durable: an event that couldn't be delivered
        // live is kept and handed over the next time this app launches, which
        // can be hours later. Acting on one of those as though it were live
        // starts a session nobody asked for — and starting a session touches
        // the player's audio.
        //
        // Three states, not two. An unstamped event means the watch is on an
        // older build than the phone, which happens routinely because watch
        // updates lag; those are handled as before rather than dropped, but
        // they are never allowed to start a session on their own.
        let age = (payload["sentAt"] as? TimeInterval)
            .map { Date().timeIntervalSince1970 - $0 }
        let isStale = (age ?? 0) > 60
        let isFresh = age.map { $0 <= 60 } ?? false
        if isStale { return }

        let capturing = payload["capturing"] as? Bool ?? false
        Task { @MainActor in
            if let sentDiscipline { self.discipline = sentDiscipline }
            // Late-join safety net: if we somehow missed sessionStart, a live
            // arm event still brings the phone up. Only a *live* one — a queued
            // event replayed at launch would open an audio session and cut
            // whatever the player is listening to, for no reason at all.
            if !self.isSessionLive, isFresh, event == "arm" || event == "takeaway" {
                self.mirrorSessionStart()
            }
            if event == "sessionStart" { self.mirrorSessionStart(capturing: capturing) }
            else { self.handle(event: event, confidence: confidence) }
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
