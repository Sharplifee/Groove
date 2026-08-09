import Foundation
import AVFoundation

/// Anything that can duck the player's media and open a live mic.
/// The paired-device route would implement this over the network; everything
/// else stays identical.
protocol AudioHost: AnyObject {
    var inputLatency: TimeInterval { get }
    var isArmed: Bool { get }
    var isAlive: Bool { get }
    func startSession() throws
    func arm(preferring route: AudioRoute) throws
    func duckAndPassthrough()
    func restore(afterTail tail: TimeInterval)
    func disarm()
    func endSession()
}

/// # Why this is two tiers
///
/// iOS grants an `audio`-background-mode app continued execution **only while an
/// audio session is active and producing samples**. Between swings this app has
/// nothing to play, so a naive design gets suspended within seconds of the phone
/// going in a pocket — CoreMotion stops, `sendMessage` stops arriving, and the
/// duck never fires again after the first shot. An earlier version of this file
/// also called `setActive(false)` on every disarm, which guaranteed it.
///
/// So the session is never fully torn down mid-round. Instead:
///
/// - **Keepalive tier** (`.playback`, silent source node) runs for the whole
///   range session. It holds background execution open. No input node, so
///   Bluetooth earbuds stay on A2DP and your podcast keeps full fidelity.
/// - **Armed tier** (`.playAndRecord`) is switched into only around a swing.
///   That's what enables the mic, and what forces HFP — so it lives for about
///   four seconds and switches back.
///
/// Changing category on an already-active session keeps execution unbroken;
/// `setActive(false)` is called exactly once, at `endSession()`.
final class LocalAudioHost: NSObject, AudioHost {

    private let engine = AVAudioEngine()
    private var silence: AVAudioSourceNode?
    private var passthroughVolume: Float = 0
    private var restoreWork: DispatchWorkItem?

    private(set) var isArmed = false
    private(set) var isAlive = false
    private var isPassingThrough = false

    var inputLatency: TimeInterval {
        AVAudioSession.sharedInstance().inputLatency
            + AVAudioSession.sharedInstance().outputLatency
    }

    var currentInputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "None"
    }

    /// Any brand of earbud exposes a mic here — Bluetooth HFP, wired, USB-C.
    var availableInputs: [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    // MARK: - Keepalive tier

    /// Called once when the range session starts and held until it ends.
    func startSession() throws {
        guard !isAlive else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default,
                                options: [.mixWithOthers])
        try session.setActive(true)

        let format = engine.outputNode.inputFormat(forBus: 0)
        let node = AVAudioSourceNode { _, _, _, audioBufferList in
            // Genuine silence, not low volume — iOS counts an active session
            // producing samples, and this costs effectively nothing.
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
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
        disarmInputOnly()
        engine.stop()
        if let silence { engine.detach(silence) }
        silence = nil
        isAlive = false
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
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try? engine.start() }
        @unknown default: break
        }
    }

    // MARK: - Armed tier

    /// Switches the live session up to `.playAndRecord`. Category changes on an
    /// active session don't interrupt background execution; deactivating would.
    func arm(preferring route: AudioRoute) throws {
        guard isAlive else { throw AudioError.sessionNotStarted }
        guard !isArmed else { return }

        let session = AVAudioSession.sharedInstance()
        engine.pause()
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.mixWithOthers, .duckOthers,
                                          .allowBluetooth, .allowBluetoothA2DP,
                                          .defaultToSpeaker])
        try session.setPreferredIOBufferDuration(0.005)
        try selectInput(for: route)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw AudioError.noInput }
        engine.connect(input, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0        // silent until takeaway
        if !engine.isRunning { try engine.start() }
        isArmed = true
    }

    func duckAndPassthrough() {
        guard isArmed else { return }
        restoreWork?.cancel()
        isPassingThrough = true
        ramp(to: 1.0, over: 0.04)
    }

    /// Called at impact. The tail is deliberate: coming back exactly at contact
    /// would step on the strike you opened the mic to hear.
    func restore(afterTail tail: TimeInterval) {
        guard isPassingThrough else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.ramp(to: 0, over: 0.35)
            self?.isPassingThrough = false
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tail, execute: work)
    }

    /// Drops back to the keepalive tier. Crucially does NOT deactivate the
    /// session — the app must stay alive between swings.
    func disarm() {
        guard isArmed else { return }
        restoreWork?.cancel()
        disarmInputOnly()

        guard isAlive else { return }
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .default, options: [.mixWithOthers])
        if !engine.isRunning { try? engine.start() }
    }

    private func disarmInputOnly() {
        if isArmed {
            engine.pause()
            engine.disconnectNodeOutput(engine.inputNode)
        }
        engine.mainMixerNode.outputVolume = 0
        isArmed = false
        isPassingThrough = false
    }

    // MARK: - Route selection

    private func selectInput(for route: AudioRoute) throws {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs, !inputs.isEmpty else { return }

        let earbudTypes: [AVAudioSession.Port] = [.bluetoothHFP, .headsetMic, .usbAudio]
        let wanted: AVAudioSessionPortDescription?
        switch route {
        case .earbuds:
            wanted = inputs.first { earbudTypes.contains($0.portType) }
                  ?? inputs.first { $0.portType == .builtInMic }
        case .phoneMic, .pairedDevice:
            wanted = inputs.first { $0.portType == .builtInMic }
        }
        if let wanted { try session.setPreferredInput(wanted) }
    }

    func routeUnavailable(_ route: AudioRoute) -> Bool {
        guard route == .earbuds else { return false }
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        return !inputs.contains {
            [.bluetoothHFP, .headsetMic, .usbAudio].contains($0.portType)
        }
    }

    // MARK: - Envelope

    private func ramp(to target: Float, over duration: TimeInterval) {
        let steps = max(1, Int(duration / 0.01))
        let start = engine.mainMixerNode.outputVolume
        for s in 0...steps {
            let f = Float(s) / Float(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(s) * 0.01) { [weak self] in
                self?.engine.mainMixerNode.outputVolume = start + (target - start) * f
            }
        }
    }

    enum AudioError: LocalizedError {
        case sessionNotStarted, noInput
        var errorDescription: String? {
            switch self {
            case .sessionNotStarted: return "Audio session isn't running."
            case .noInput:           return "No microphone is available on this route."
            }
        }
    }
}
