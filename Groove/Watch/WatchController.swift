import Foundation
import CoreMotion
import HealthKit
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

/// Watch orchestration. The detector lives here because latency matters:
/// takeaway → phone → mic open has to finish inside the backswing.
@MainActor
final class WatchController: NSObject, ObservableObject {

    @Published var state: DetectorState = .watching
    @Published var struckCount = 0
    @Published var rehearsalCount = 0
    @Published var lastTempo: Double = 0
    /// Struck tempos this session, oldest first — feeds the live consistency
    /// strip on the face. Capped so an all-day range session can't grow it.
    @Published var tempos: [Double] = []
    /// Diagnostic capture: while true, every raw frame and every detector
    /// decision is being written down for export and offline replay.
    @Published var isCapturing = false
    /// True while a running session is actually recording (isCapturing arms it).
    @Published var capturingLive = false
    private var capture: CaptureRecorder?
    @Published var armConfidence: Double = 0
    @Published var plateauCount = 0
    @Published var isRunning = false
    @Published var status = "Ready"
    @Published var phoneConfigured = false
    /// Published so the UI actually re-renders when the phone comes and goes.
    /// A bare computed property had no publisher behind it.
    @Published var phoneReady = false
    @Published var unsentSwings = 0

    /// What you're about to practise. Picked on the watch because that is where
    /// you are when you decide — walking from the range to the putting green,
    /// with the phone already in a pocket.
    ///
    /// Changing this changes the detector's numbers, not a label: impact
    /// threshold, trace window, and whether audio is touched at all. Locked
    /// while a session runs, because traces from two disciplines must never
    /// stack together — the ensemble would align two different motions on the
    /// same index and read the difference as inconsistency.
    @Published var discipline: Discipline = .fullSwing {
        didSet {
            guard !isRunning else { discipline = oldValue; return }
            queue.addOperation { [self] in detector.discipline = discipline }
        }
    }

    private let motion = CMMotionManager()
    private let healthStore = HKHealthStore()
    private let detector = RoutineDetector()
    private let spool = SwingSpool()
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var t0 = Date()
    private var sessionID = UUID()

    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive; return q
    }()

    override init() {
        super.init()
        detector.delegate = self
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Shown on the watch face when something structural is stopping a session.
    @Published var blocker: String?

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            blocker = "This watch can't run sessions."
            return
        }
        let share: Set = [HKQuantityType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType.workoutType(), HKQuantityType(.heartRate)]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
        } catch {
            // A denial here means no workout session, which means CoreMotion
            // stops the moment the screen sleeps. Say so instead of failing later.
            blocker = "Allow Workouts in Settings — sensors stop without it."
            return
        }
        if healthStore.authorizationStatus(for: HKQuantityType.workoutType()) == .sharingDenied {
            blocker = "Allow Workouts in Settings — sensors stop without it."
        } else {
            blocker = nil
        }
    }

    /// Applied whenever the phone pushes new settings, mid-session included.
    func apply(_ config: Config) {
        queue.addOperation { [self] in
            detector.config = config
            detector.discipline = discipline
        }
        config.save()               // local cache for a cold start with no phone
        phoneConfigured = true
    }

    private func refreshReachability() {
        let s = WCSession.default
        phoneReady = s.activationState == .activated && s.isReachable
    }

    // MARK: Session

    func start() {
        guard !isRunning else { return }
        do {
            // Not for fitness data — this is the only supported way to hold
            // CoreMotion at 100 Hz with the screen off on watchOS.
            let config = HKWorkoutConfiguration()
            config.activityType = .golf
            config.locationType = .outdoor
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                         workoutConfiguration: config)
            session.delegate = self
            let now = Date()
            session.startActivity(with: now)
            builder.beginCollection(withStart: now) { _, _ in }
            self.workout = session; self.builder = builder

            // Prefer the phone's config over our local copy — UserDefaults do
            // not cross devices, so the local one is almost certainly defaults.
            let cfg = ConfigSync.currentFromPhone() ?? Config.load()
            queue.addOperation { [self] in
                detector.config = cfg
                detector.discipline = discipline
                detector.reset()
            }
            t0 = Date()
            sessionID = UUID()
            struckCount = 0
            rehearsalCount = 0
            lastTempo = 0
            tempos = []
            plateauCount = 0

            motion.deviceMotionUpdateInterval = 1.0 / SwingAnalyzer.fs
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
                guard let self, let dm else { return }
                let frame = MotionFrame(
                    t: Date().timeIntervalSince(self.t0),
                    accel: SIMD3(dm.userAcceleration.x, dm.userAcceleration.y, dm.userAcceleration.z),
                    rotation: SIMD3(dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z),
                    gravity: SIMD3(dm.gravity.x, dm.gravity.y, dm.gravity.z))
                // Already on the serial capture queue — feed the detector
                // here. The old version allocated a main-actor Task for every
                // frame, a hundred a second, which ran the whole detector on
                // the UI thread in a straight fight with SwiftUI rendering —
                // that was the on-wrist lag. Delegate events (a few per swing,
                // not per frame) hop to main inside their handlers instead.
                self.capture?.append(frame)
                self.detector.ingest(frame)
            }
            isRunning = true
            status = "Watching"
            // The watch owns the session. The phone mirrors this, never the reverse —
            // it's in a back pocket and can't be the control surface.
            // The phone needs the discipline to pick the matching pelvis
            // threshold. It rides on the session-start event rather than
            // ConfigSync because it changes per session, not per setup.
            if isCapturing {
                capturingLive = true
                let rec = CaptureRecorder(device: "watch", discipline: discipline)
                queue.addOperation { [self] in
                    capture = rec
                    detector.onTrace = { [weak self] t, label in
                        self?.capture?.mark(t, label)
                    }
                }
            }
            send(["event": "sessionStart",
                  "sessionID": sessionID.uuidString,
                  "discipline": discipline.rawValue,
                  "capturing": isCapturing])
        } catch {
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        let end = Date()
        builder?.endCollection(withEnd: end) { [weak self] _, _ in
            self?.builder?.finishWorkout { _, _ in }
        }
        workout?.end(); workout = nil
        isRunning = false
        state = .watching
        status = "Ended"
        send(["event": "sessionEnd"])
        if isCapturing {
            queue.addOperation { [self] in
                defer { capture = nil; detector.onTrace = nil }
                guard let rec = capture, let data = try? rec.data() else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("watch-capture-\(Int(Date().timeIntervalSince1970)).json")
                guard (try? data.write(to: url)) != nil else { return }
                WCSession.default.transferFile(url, metadata: ["kind": "capture"])
            }
            isCapturing = false
            capturingLive = false
        }
    }

    // MARK: Phone link

    /// Swings are held on the watch until the phone confirms delivery. Before
    /// this, a permanently failed transfer just lost them.
    func flushSpool() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        for swing in spool.pending() {
            guard let data = try? JSONEncoder().encode(swing) else {
                spool.remove(swing.id); continue
            }
            session.transferUserInfo(["swing": data, "swingID": swing.id.uuidString])
        }
    }

    func acknowledge(_ id: UUID) {
        spool.remove(id)
        unsentSwings = spool.count
    }

    private func send(_ payload: [String: Any]) {
        var payload = payload
        // Stamped so the phone can tell a live event from one that has been
        // sitting in the queue since a previous round. `transferUserInfo`
        // delivers durably — including on the next app launch, hours later.
        payload["sentAt"] = Date().timeIntervalSince1970
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil) { _ in
                s.transferUserInfo(payload)     // queue it if the live path fails
            }
        } else {
            s.transferUserInfo(payload)
        }
    }
}

// MARK: - Detector delegate

extension WatchController: RoutineDetectorDelegate {
    // The detector fires these from the capture queue now. Each hops to the
    // main actor once per EVENT — a few per swing — where the old design paid
    // that price per FRAME. Sub-millisecond scheduling on a path where the
    // phone's audio ramp is the long pole anyway.
    nonisolated func detectorDidArm(confidence: Double) {
      Task { @MainActor in
        state = .armed
        armConfidence = confidence
        // Arming early gives the phone time to open the record session before
        // the duck is actually needed.
        send(["event": "arm", "confidence": confidence])
        // The only haptic you feel before a shot, and it lands while you're
        // still — never mid-motion.
        Haptic.arm()
      }
    }

    nonisolated func detectorDidDisarm() {
      Task { @MainActor in
        state = .watching
        send(["event": "disarm"])
      }
    }

    nonisolated func detectorDidFireTakeaway(confidence: Double) {
      Task { @MainActor in
        state = .swinging
        // A putt has almost no sound worth exposing, so ducking forty times an
        // hour on a practice green would be pure irritation. The stroke is still
        // recorded — it just doesn't touch the player's audio.
        guard discipline.ducksAudio else { return }
        send(["event": "takeaway", "confidence": confidence])
        // Deliberately silent. Buzzing a player's wrist at the instant their
        // backswing starts is the worst possible moment to interrupt them.
      }
    }

    nonisolated func detectorDidCompleteSwing(_ swing: Swing, wasArmed: Bool) {
      Task { @MainActor in
        state = .recovering

        // Only tell the phone to touch audio if this swing actually armed it.
        // An unarmed swing is still logged — capture is independent of arming.
        if swing.struck {
            struckCount += 1
            lastTempo = swing.metrics.tempoRatio
            if swing.metrics.tempoRatio > 0 {
                tempos.append(swing.metrics.tempoRatio)
                if tempos.count > 200 { tempos.removeFirst() }
            }
            if wasArmed { send(["event": "impact"]) }
            // Confirms the swing logged, so he never has to look at the watch.
            Haptic.captured()
        } else {
            rehearsalCount += 1
            if wasArmed { send(["event": "restore"]) }   // no ball — audio back now
        }
        plateauCount = swing.routine.plateauCount

        var stamped = swing
        stamped.sessionID = sessionID
        spool.enqueue(stamped)
        flushSpool()
        unsentSwings = spool.count
      }
    }
}

// MARK: - Delegates

extension WatchController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Workout error: \(error.localizedDescription)" }
    }
}

extension WatchController: WCSessionDelegate {
    nonisolated func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.refreshReachability()
            self.unsentSwings = self.spool.count
            self.flushSpool()
        }
        if let config = ConfigSync.decode(s.receivedApplicationContext) {
            Task { @MainActor in self.apply(config) }
        }
    }

    nonisolated func session(_ s: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let config = ConfigSync.decode(context) else { return }
        Task { @MainActor in self.apply(config) }
    }

    nonisolated func sessionReachabilityDidChange(_ s: WCSession) {
        Task { @MainActor in
            self.refreshReachability()
            if s.isReachable { self.flushSpool() }   // catch up on anything stranded
        }
    }

    /// Phone confirms receipt so the spool can drop it.
    nonisolated func session(_ s: WCSession, didReceiveMessage message: [String: Any]) {
        guard let raw = message["ack"] as? String, let id = UUID(uuidString: raw) else { return }
        Task { @MainActor in self.acknowledge(id) }
    }
}

/// Two haptic moments, both outside the swing itself.
enum Haptic {
    /// You're set and it's watching. Fires while you're still.
    static func arm() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.start)
        #endif
    }
    /// Swing logged. Fires after you've finished, so you never check the watch.
    static func captured() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.success)
        #endif
    }
}


// MARK: - Spool

/// Durable queue of swings not yet confirmed by the phone. Survives app relaunch,
/// so a lost or delayed transfer never costs a rep.
final class SwingSpool {
    private let key = "groove.spool"

    private var items: [Swing] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode([Swing].self, from: d) else { return [] }
            return s
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: key)
            }
        }
    }

    var count: Int { items.count }
    func pending() -> [Swing] { items }
    func enqueue(_ swing: Swing) { items.append(swing) }
    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
}
