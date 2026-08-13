import Foundation
import AVFoundation

/// Anything that can duck the player's media and replay the strike.
/// The paired-device route would implement this over the network; everything
/// else stays identical.
protocol AudioHost: AnyObject {
    var isArmed: Bool { get }
    var isAlive: Bool { get }
    func startSession() throws
    func arm(preferring route: AudioRoute) throws
    func duckForTakeaway()
    func fireImpactBurst()
    func restore(afterTail tail: TimeInterval)
    func disarm()
    func endSession()
}

/// # Why there is no live passthrough any more
///
/// The old design opened the mic and streamed room audio to the earbuds for the
/// duration of a swing. Two things were wrong with that, and only one of them
/// was a settings problem.
///
/// **The music quality.** Asking for `.allowBluetooth` alongside `.playAndRecord`
/// makes iOS negotiate HFP so it can reach the earbud microphone — mono, 8-16 kHz,
/// for as long as the session is armed. That is what made a podcast sound thin.
/// The fix is to never ask for it: `.allowBluetoothA2DP` keeps output on full
/// stereo, and input comes from the phone's own mic, which is what a pocketed
/// phone was going to use anyway.
///
/// **The echo.** That one is not tunable. Bluetooth output latency runs
/// 150-250 ms, so a streamed copy of the strike always arrives well after the
/// real strike the player already heard through the earbud seal. Two of the same
/// transient offset by a fifth of a second is a slapback, and no amount of gain
/// shaping removes it.
///
/// So nothing is streamed. A rolling buffer is always capturing but never
/// audible; at impact the transient is sliced out and played back exactly once.
/// A single burst has nothing to beat against, so there is no echo.
///
/// # Why there is only one tier now
///
/// The previous two-tier design — silent `.playback` between swings, switching
/// up to `.playAndRecord` around each one — existed solely because the record
/// tier forced HFP and had to be kept short. Without `.allowBluetooth` that
/// penalty is gone, so the session stays in `.playAndRecord` for the whole
/// round and there is no category-switch window for a fast second shot to land
/// in.
///
/// The silent source node is unchanged and load-bearing: iOS grants an
/// `audio`-background-mode app continued execution only while a session is
/// active and producing samples, and between swings this app has nothing to
/// play. `setActive(false)` is called in exactly one place, `endSession()`.
final class LocalAudioHost: NSObject, AudioHost {

    // MARK: Burst shape - tune these at the range.

    /// How much of the transient to replay.
    static var burstWindow: TimeInterval = 0.130
    /// Captured before the detected impact, so the burst opens with the club
    /// arriving rather than starting halfway through the crack.
    static var burstPreRoll: TimeInterval = 0.018
    /// Slice edges click without these.
    static var burstFade: TimeInterval = 0.006
    /// Replay gain. The point is to make the strike unmissable over ducked
    /// media, not to be loud.
    static var burstGain: Float = 1.6

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var silence: AVAudioSourceNode?
    private var restoreWork: DispatchWorkItem?

    /// Always capturing, never routed to the output. This is the only thing the
    /// microphone is used for, and nothing is written to disk.
    private var ring: [Float] = []
    private var ringWrite = 0
    private var ringFilled = false
    private var ringRate: Double = 48_000
    private let ringSeconds: Double = 2.0
    private let ringLock = NSLock()

    private(set) var isArmed = false
    private(set) var isAlive = false
    private var isDucked = false

    var currentInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "None"
    }

    var currentOutputName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "None"
    }

    /// True while the route is still a full-fidelity stereo link. If this ever
    /// goes false mid-session the option set is wrong - HFP has been negotiated
    /// and the player's music has just been degraded.
    var outputIsHighFidelity: Bool {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return !outs.contains { $0.portType == .bluetoothHFP }
    }

    // MARK: - Session

    /// `.allowBluetooth` is deliberately absent and must stay absent - it is
    /// what negotiates HFP and collapses the player's music to mono.
    private var baseOptions: AVAudioSession.CategoryOptions {
        [.allowBluetoothA2DP, .mixWithOthers]
    }

    /// Options for the recording tier. `.defaultToSpeaker` only belongs here —
    /// on `.playback` it does nothing, and on an idle session it invites a route
    /// change the player never asked for.
    private var recordOptions: AVAudioSession.CategoryOptions {
        baseOptions.union(.defaultToSpeaker)
    }

    /// Called once when the range session starts and held until it ends.
    ///
    /// Deliberately `.playback`, not `.playAndRecord`. Activating a recording
    /// category is an intrusive act: iOS treats it as the app wanting the
    /// microphone, and whatever the player was listening to can be interrupted
    /// even with `.mixWithOthers` set. The keepalive tier has no reason to
    /// record — it exists purely so iOS keeps the app running in a pocket — so
    /// it asks for nothing it doesn't need. The microphone is only engaged in
    /// `arm()`, roughly a second before a swing.
    func startSession() throws {
        guard !isAlive else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: baseOptions)
        try session.setActive(true)

        let outFormat = engine.outputNode.inputFormat(forBus: 0)

        // Genuine silence, not low volume - iOS counts an active session
        // producing samples, and this costs effectively nothing.
        let node = AVAudioSourceNode { _, _, _, audioBufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outFormat)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        engine.prepare()
        try engine.start()

        silence = node
        isAlive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: session)
    }

    /// The only place the session is deactivated.
    func endSession() {
        restoreWork?.cancel()
        stopCapture()
        player.stop()
        engine.stop()
        if let silence { engine.detach(silence) }
        silence = nil
        isAlive = false
        isDucked = false
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// A phone call or Siri kills the session. Without this the app stays
    /// backgrounded but dead for the rest of the round.
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isArmed = false
        case .ended:
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: baseOptions)
            try? session.setActive(true)
            if !engine.isRunning { try? engine.start() }
        @unknown default: break
        }
    }

    // MARK: - Capture

    /// Starts the rolling buffer. No category change, no route change, nothing
    /// audible - the tap exists only so there is something to slice at impact.
    func arm(preferring route: AudioRoute) throws {
        // Route is no longer used to pick an input. Without `.allowBluetooth`
        // there is no earbud mic to choose, so capture always comes from the
        // phone — which is where a pocketed phone was recording from anyway.
        _ = route
        guard isAlive else { throw AudioError.sessionNotStarted }
        guard !isArmed else { return }

        // Step up to the recording tier only now. This is the one moment the
        // microphone is needed, and it happens about a second before the ball
        // is struck — the app is not holding the mic open across a whole round.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: recordOptions)

        // The engine has to be rebuilt around the new category or the input node
        // reports a zero format and the tap silently captures nothing.
        engine.stop()
        try engine.start()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInput }

        ringLock.lock()
        ringRate = format.sampleRate
        ring = [Float](repeating: 0, count: Int(format.sampleRate * ringSeconds))
        ringWrite = 0
        ringFilled = false
        ringLock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            self?.append(buf)
        }
        isArmed = true
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        ringLock.lock()
        defer { ringLock.unlock() }
        guard !ring.isEmpty else { return }
        for i in 0..<n {
            ring[ringWrite] = channel[i]
            ringWrite += 1
            if ringWrite == ring.count { ringWrite = 0; ringFilled = true }
        }
    }

    private func stopCapture() {
        guard isArmed else { return }
        engine.inputNode.removeTap(onBus: 0)
        isArmed = false
        // Drop straight back to the non-recording tier. Holding `.playAndRecord`
        // between swings shows the orange microphone dot for the whole round and
        // gives iOS a reason to interrupt the player's audio that it does not
        // need to have.
        guard isAlive else { return }
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .default, options: baseOptions)
    }

    // MARK: - Duck and burst

    /// Takeaway. Adds `.duckOthers` to the live session so the player's media
    /// drops. Setting the category on an already-active session does not
    /// interrupt background execution - deactivating would.
    func duckForTakeaway() {
        guard isAlive, !isDucked else { return }
        restoreWork?.cancel()
        // Whichever tier is current, add ducking to it rather than assuming one.
        let session = AVAudioSession.sharedInstance()
        let category: AVAudioSession.Category = isArmed ? .playAndRecord : .playback
        let options = (isArmed ? recordOptions : baseOptions).union(.duckOthers)
        try? session.setCategory(category, mode: .default, options: options)
        isDucked = true
    }

    /// Impact. Slices the transient out of the rolling buffer and plays it once.
    /// The real strike has already reached the player's ears through the earbud
    /// seal; this is the amplified copy landing on top of ducked media, not a
    /// second live feed to beat against it.
    func fireImpactBurst() {
        guard isAlive, isArmed else { return }

        ringLock.lock()
        let rate = ringRate
        let capacity = ring.count
        let write = ringWrite
        let filled = ringFilled
        guard capacity > 0, filled || write > 0 else { ringLock.unlock(); return }

        let window = Int(rate * Self.burstWindow)
        let preRoll = Int(rate * Self.burstPreRoll)
        let available = filled ? capacity : write
        let count = min(window, available)
        guard count > 32 else { ringLock.unlock(); return }

        // The tap runs behind real time, so the newest sample sits just before
        // the write head. Back up by the pre-roll, then take the window.
        var slice = [Float](repeating: 0, count: count)
        var read = write - preRoll - count
        while read < 0 { read += capacity }
        for i in 0..<count {
            slice[i] = ring[(read + i) % capacity]
        }
        ringLock.unlock()

        applyFades(&slice, rate: rate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(count)),
              let dst = buffer.floatChannelData?[0] else { return }
        for i in 0..<count { dst[i] = slice[i] * Self.burstGain }
        buffer.frameLength = AVAudioFrameCount(count)

        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    private func applyFades(_ s: inout [Float], rate: Double) {
        let f = min(Int(rate * Self.burstFade), s.count / 2)
        guard f > 1 else { return }
        for i in 0..<f {
            let g = Float(i) / Float(f)
            s[i] *= g
            s[s.count - 1 - i] *= g
        }
    }

    /// Called after impact. The tail is deliberate: restoring the media exactly
    /// at contact would step on the strike the duck existed to expose.
    func restore(afterTail tail: TimeInterval) {
        guard isDucked else { return }
        let work = DispatchWorkItem { [weak self] in self?.unduck() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tail, execute: work)
    }

    private func unduck() {
        guard isAlive else { return }
        let category: AVAudioSession.Category = isArmed ? .playAndRecord : .playback
        try? AVAudioSession.sharedInstance()
            .setCategory(category, mode: .default,
                         options: isArmed ? recordOptions : baseOptions)
        isDucked = false
    }

    /// Stops capturing between swings. Crucially does NOT deactivate the
    /// session - the app must stay alive in the pocket.
    func disarm() {
        restoreWork?.cancel()
        unduck()
        stopCapture()
        if isAlive, !engine.isRunning { try? engine.start() }
    }

    enum AudioError: LocalizedError {
        case sessionNotStarted, noInput
        var errorDescription: String? {
            switch self {
            case .sessionNotStarted: return "Audio session isn't running."
            case .noInput:           return "No microphone is available."
            }
        }
    }
}
