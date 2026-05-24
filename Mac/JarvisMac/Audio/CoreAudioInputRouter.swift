import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Phase-1's gap was that AVAudioEngine always followed the system-default
/// input. This router takes a user-chosen `AVCaptureDevice.uniqueID`,
/// resolves it to a CoreAudio `AudioDeviceID`, and sets it as the current
/// device on the engine's input audio unit (HAL output unit in input mode).
///
/// `engine.inputNode` exposes `audioUnit` (AUHAL). Setting
/// `kAudioOutputUnitProperty_CurrentDevice` on its global scope picks the
/// hardware to read from, before `engine.prepare()`.
enum CoreAudioInputRouter {

    enum RouteResult {
        case routedTo(deviceID: AudioDeviceID, name: String)
        case fellBackToDefault(reason: String)
        case failed(String)
    }

    /// Attempt to route the engine's input to the device whose
    /// `AVCaptureDevice.uniqueID` matches `uid`. If `uid` is nil or
    /// unmatchable, leaves the engine on the system default.
    @discardableResult
    static func route(engine: AVAudioEngine, toUID uid: String?) -> RouteResult {
        guard let uid else {
            return .fellBackToDefault(reason: "No preferred device")
        }
        guard let inputUnit = engine.inputNode.audioUnit else {
            return .failed("inputNode has no audio unit")
        }
        guard let deviceID = audioDeviceID(forUID: uid) else {
            return .fellBackToDefault(reason: "UID not resolvable")
        }

        var dev = deviceID
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            return .failed("AudioUnitSetProperty failed (\(status))")
        }
        return .routedTo(deviceID: deviceID, name: nameOf(deviceID) ?? "?")
    }

    /// Resolve an AVCaptureDevice uniqueID to a CoreAudio AudioDeviceID by
    /// walking the kAudioHardwarePropertyDevices list and matching UIDs.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        for device in inputDevices() where uidOf(device) == uid {
            return device
        }
        return nil
    }

    static func inputDevices() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.filter { hasInputStreams($0) }
    }

    static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr
        else { return false }
        return size > 0
    }

    static func uidOf(_ device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid as String?
    }

    static func nameOf(_ device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name as String?
    }
}
