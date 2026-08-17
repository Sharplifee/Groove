import Foundation

// MARK: - Diagnostic capture
//
// Press record, and both devices write down everything: every motion frame the
// sensors produce, at full rate, alongside a narrative of every decision the
// detector made about those frames. The point is replay — the detector is pure
// shared code, so a capture taken on the range can be fed back through the
// exact same engine on any machine, misfire by misfire, until the logic and
// the reality agree. Field data beats synthetic data; this is how field data
// gets off the wrist.
//
// The format is deliberately dumb: frames are rows of ten numbers in a fixed
// column order, because a 15-minute capture is ~90k frames and Codable structs
// per frame would triple the size for nothing.

/// Column order for every frame row. If this ever changes, `version` changes.
/// [t, ax, ay, az, rx, ry, rz, gx, gy, gz]
public enum CaptureColumns {
    public static let count = 10
    public static let version = 1
}

struct CaptureEventRow: Codable, Equatable {
    let t: TimeInterval
    let label: String
}

/// One device's worth of a capture session.
struct CaptureStream: Codable, Equatable {
    var device: String                 // "watch" | "phone"
    var discipline: String
    var startedAt: Date
    var columns: Int = CaptureColumns.count
    var version: Int = CaptureColumns.version
    var frames: [[Double]] = []
    var events: [CaptureEventRow] = []
}

/// The file the player actually exports: both devices, one JSON.
struct CaptureBundle: Codable, Equatable {
    var watch: CaptureStream?
    var phone: CaptureStream?
    var notes: String = ""
}

/// Appends frames and decision events; serialises on demand. Not thread-safe
/// by itself — own it from one queue, the same rule as the frame buffers.
final class CaptureRecorder {
    private(set) var stream: CaptureStream
    /// ~20 minutes at 100 Hz. Beyond this the capture stops growing rather
    /// than eating the device; the file says so in its events.
    private let frameCap = 120_000
    private var capped = false

    init(device: String, discipline: Discipline) {
        stream = CaptureStream(device: device,
                               discipline: discipline.rawValue,
                               startedAt: Date())
    }

    func append(_ f: MotionFrame) {
        guard stream.frames.count < frameCap else {
            if !capped {
                capped = true
                stream.events.append(.init(t: f.t, label: "capture cap reached — recording stopped growing"))
            }
            return
        }
        stream.frames.append([f.t,
                              f.accel.x, f.accel.y, f.accel.z,
                              f.rotation.x, f.rotation.y, f.rotation.z,
                              f.gravity.x, f.gravity.y, f.gravity.z])
    }

    func mark(_ t: TimeInterval, _ label: String) {
        stream.events.append(.init(t: t, label: label))
    }

    func data() throws -> Data { try JSONEncoder().encode(stream) }

    /// Frames back out of a stream — the replay direction.
    static func frames(of s: CaptureStream) -> [MotionFrame] {
        s.frames.compactMap { r in
            guard r.count == CaptureColumns.count else { return nil }
            return MotionFrame(t: r[0],
                               accel: SIMD3(r[1], r[2], r[3]),
                               rotation: SIMD3(r[4], r[5], r[6]),
                               gravity: SIMD3(r[7], r[8], r[9]))
        }
    }
}
