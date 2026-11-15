import CoreAudio
import Foundation

/// Lowers the default output device's volume while the dictation key is held and
/// restores it as soon as recording stops. Restores only if the volume is still
/// at the level we set, so manual changes made during dictation are respected.
@MainActor
final class VolumeDuckingService {
    static let shared = VolumeDuckingService()

    private struct Ducked {
        let deviceID: AudioDeviceID
        let originals: [UInt32: Float32] // element -> original scalar
        let applied: [UInt32: Float32]
    }

    private var ducked: Ducked?

    func recordingStarted(enabled: Bool, level: Double) {
        // A new recording while still ducked (previous restore pending) keeps the original.
        guard enabled, self.ducked == nil else { return }
        guard let device = Self.defaultOutputDevice() else { return }
        let elements = Self.volumeElements(device)
        guard !elements.isEmpty else {
            DebugLogger.shared.info("VOLUME_DUCK unsupported_device", source: "VolumeDuckingService")
            return
        }
        let factor = Float32(min(max(level, 0), 1))
        var originals: [UInt32: Float32] = [:]
        var applied: [UInt32: Float32] = [:]
        for element in elements {
            guard let current = Self.getVolume(device, element) else { continue }
            let target = current * factor
            guard Self.setVolume(device, element, target) else { continue }
            originals[element] = current
            applied[element] = target
        }
        guard !originals.isEmpty else { return }
        self.ducked = Ducked(deviceID: device, originals: originals, applied: applied)
        DebugLogger.shared.info("VOLUME_DUCK ducked factor=\(factor)", source: "VolumeDuckingService")
    }

    func recordingStopped() {
        guard let ducked = self.ducked else { return }
        self.ducked = nil
        for (element, original) in ducked.originals {
            guard let now = Self.getVolume(ducked.deviceID, element),
                  let applied = ducked.applied[element],
                  abs(now - applied) < 0.02 else { continue } // user changed it; leave alone
            _ = Self.setVolume(ducked.deviceID, element, original)
        }
        DebugLogger.shared.info("VOLUME_DUCK restored", source: "VolumeDuckingService")
    }

    // MARK: - CoreAudio

    private static func address(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Main element (0) if the device has one, otherwise per-channel 1 and 2.
    private static func volumeElements(_ device: AudioDeviceID) -> [UInt32] {
        for candidates in [[UInt32(0)], [1, 2]] {
            let ok = candidates.allSatisfy { element in
                var addr = address(element)
                var settable = DarwinBoolean(false)
                return AudioObjectHasProperty(device, &addr)
                    && AudioObjectIsPropertySettable(device, &addr, &settable) == noErr
                    && settable.boolValue
            }
            if ok { return candidates }
        }
        return []
    }

    private static func getVolume(_ device: AudioDeviceID, _ element: UInt32) -> Float32? {
        var addr = address(element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setVolume(_ device: AudioDeviceID, _ element: UInt32, _ value: Float32) -> Bool {
        var addr = address(element)
        var v = value
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}
