import Foundation
import WatchConnectivity

/// Config lives in `UserDefaults`, which is **not** shared between a phone and
/// its watch — they're separate domains on separate devices. Before this existed
/// the watch silently ran on defaults no matter what you set on the phone, so
/// handedness, watch wrist, and sensitivity were all ignored by the detector
/// that depends on them.
///
/// `updateApplicationContext` is the right transport: it's a single latest-value
/// slot that survives the counterpart app being asleep and delivers on next wake.
enum ConfigSync {

    private static let key = "config"

    /// Phone → watch. Safe to call on every change; the system coalesces.
    static func push(_ config: Config) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(config) else { return }
        try? session.updateApplicationContext([key: data])
    }

    /// Watch side: pull whatever the phone last sent, falling back to whatever
    /// we already had locally.
    static func decode(_ context: [String: Any]) -> Config? {
        guard let data = context[key] as? Data,
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return config
    }

    /// Reads the context already waiting at activation, so a freshly launched
    /// watch app doesn't run a whole session on stale settings.
    static func currentFromPhone() -> Config? {
        guard WCSession.isSupported() else { return nil }
        return decode(WCSession.default.receivedApplicationContext)
    }
}
