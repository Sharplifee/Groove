import Foundation
import AVFoundation
import CoreMotion
import UIKit
import SwiftUI

/// Everything that has to be granted before a session can survive a pocket.
///
/// These used to be discovered mid-round: the mic prompt fired implicitly on the
/// first `setActive`, a denial was swallowed by `try?`, and HealthKit only
/// surfaced as a status string. All of it is now checked up front and stated
/// plainly, because every one of these failing means the app silently does
/// nothing rather than visibly breaking.
@MainActor
final class Permissions: ObservableObject {

    enum State: Equatable { case unknown, granted, denied, unavailable }

    @Published private(set) var microphone: State = .unknown
    @Published private(set) var motion: State = .unknown

    /// True only when a session can actually run unattended.
    var readyForBackground: Bool { microphone == .granted && motion != .denied }

    /// One line naming what's actually wrong, or nil.
    var blocker: String? {
        if microphone == .denied {
            return "Microphone is off. Without it there's nothing to pipe the strike through."
        }
        if motion == .denied {
            return "Motion access is off. Your pocket won't register anything."
        }
        if microphone == .unknown { return "Microphone hasn't been allowed yet." }
        return nil
    }

    // MARK: Requests

    func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = .granted
        case .denied:  microphone = .denied
        default:       microphone = .unknown
        }
        motion = CMMotionManager().isDeviceMotionAvailable ? .granted : .unavailable
    }

    /// Ask for everything in one pass, during onboarding.
    func requestAll() async {
        await requestMicrophone()
        refresh()
    }

    func requestMicrophone() async {
        let granted = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        microphone = granted ? .granted : .denied
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Preflight UI

/// Shown during onboarding and again on the Range tab if anything regresses.
struct PermissionRow: View {
    let title: String
    let detail: String
    let state: Permissions.State
    var onFix: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 17))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.muted)
            }
            Spacer()
            if state == .denied, let onFix {
                Button("Fix", action: onFix).font(.caption.bold()).tint(.alert)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch state {
        case .granted:     return "checkmark.circle.fill"
        case .denied:      return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle"
        case .unknown:     return "circle"
        }
    }
    private var tint: Color {
        switch state {
        case .granted: return .turf
        case .denied:  return .alert
        default:       return .muted
        }
    }
}
