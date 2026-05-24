import Foundation
import AVFoundation

/// Discovers connected audio input devices and remembers which one the user
/// chose. Webcam microphones are deprioritised (sorted last) so the user's
/// explicit pick is honoured even if a webcam mic becomes "default".
@MainActor
final class AudioDeviceManager {
    struct Device: Identifiable, Equatable {
        let id: String       // AVCaptureDevice uniqueID
        let name: String
        let isWebcamMic: Bool
    }

    private let prefs: PreferencesStore

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    func enumerate() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = session.devices.map { dev -> Device in
            let lower = dev.localizedName.lowercased()
            let webcam = lower.contains("cam") || lower.contains("webcam")
                      || lower.contains("brio") || lower.contains("logitech")
            return Device(id: dev.uniqueID,
                          name: dev.localizedName,
                          isWebcamMic: webcam)
        }
        // Real mics first, webcam mics last; stable name order within each group.
        return devices.sorted { lhs, rhs in
            if lhs.isWebcamMic != rhs.isWebcamMic { return !lhs.isWebcamMic }
            return lhs.name < rhs.name
        }
    }

    func setPreferred(_ device: Device?) {
        prefs.update { $0.preferredMicrophoneUID = device?.id }
    }

    var preferredUID: String? { prefs.current.preferredMicrophoneUID }

    /// Resolve the AVCaptureDevice the user chose, falling back to the
    /// system default microphone if their pick is gone (e.g. unplugged USB).
    /// Webcam mics never get auto-promoted to default — if the user's
    /// chosen device is unavailable and the system default is a webcam mic,
    /// we still prefer the next available real mic.
    func resolvePreferred() -> AVCaptureDevice? {
        if let uid = preferredUID,
           let dev = AVCaptureDevice(uniqueID: uid) {
            return dev
        }
        let listed = enumerate()
        // Real mics first per `enumerate` sort.
        if let realFirst = listed.first(where: { !$0.isWebcamMic }),
           let dev = AVCaptureDevice(uniqueID: realFirst.id) {
            return dev
        }
        return AVCaptureDevice.default(for: .audio)
    }
}
