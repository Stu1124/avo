import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Selects Avo's input device without changing the system-wide default microphone.
enum AudioInputDevice {
    static let builtInChoiceID = "__builtInMicrophone__"

    private struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let builtIn: Bool
    }

    static var pickerOptions: [(id: String, label: String)] {
        let devices = inputDevices()
        var options: [(id: String, label: String)] = []
        if let builtIn = devices.first(where: \.builtIn) {
            options.append((builtInChoiceID, builtIn.name))
        }
        options.append(contentsOf: devices.filter { !$0.builtIn }.map { ($0.uid, $0.name) })
        return options
    }

    /// Binds an AVAudioEngine input node to Avo's selected microphone, falling back to built-in.
    /// Returns the selected device name, or nil when this Mac has no audio input.
    static func useConfiguredMicrophone(for input: AVAudioInputNode, preferredUID: String) throws -> String? {
        let devices = inputDevices()
        let selected: Device?
        if preferredUID == builtInChoiceID {
            selected = devices.first(where: \.builtIn)
        } else {
            selected = devices.first(where: { $0.uid == preferredUID }) ?? devices.first(where: \.builtIn)
        }
        guard let selected else { return nil }
        guard let audioUnit = input.audioUnit else {
            throw NSError(domain: "Avo.AudioInputDevice", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio input unit is unavailable"])
        }

        // Binding the unit to a device is a one-time operation, but Avo reuses one AVAudioEngine
        // across holds and asks for the device on every prepare and every start. A fresh unit reports
        // AVAudioEngine's own private device, never the target, so the first call always has work to
        // do; every later call on that engine re-applies a device the unit already holds. Core Audio
        // sometimes rejects that no-op re-application with kAudioHardwareIllegalOperationError
        // ('nope', 1852797029) — the source of the "input selection failed" warnings, all of which
        // were re-applications on an engine that had been sitting prepared since an earlier call.
        // Skipping it changes no routing: the unit already has exactly this device.
        if currentDevice(of: audioUnit) == selected.id { return selected.name }

        var deviceID = selected.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Could not select \(selected.name) (device \(selected.id), unit had \(currentDevice(of: audioUnit).map(String.init) ?? "unknown"), Core Audio \(status))"])
        }
        return selected.name
    }

    /// The device an audio unit is currently bound to, or nil when the unit will not say.
    private static func currentDevice(of audioUnit: AudioUnit) -> AudioDeviceID? {
        var device: AudioDeviceID = kAudioObjectUnknown
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &device, &byteCount) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &byteCount) == noErr,
              byteCount >= MemoryLayout<AudioDeviceID>.size else { return [] }

        var devices = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, &devices) == noErr else { return [] }

        return devices.compactMap { device -> Device? in
            guard hasInputStreams(device),
                  let uid = propertyString(device, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let transport = propertyUInt32(device, selector: kAudioDevicePropertyTransportType)
            return Device(
                id: device,
                uid: uid,
                name: propertyString(device, selector: kAudioObjectPropertyName) ?? "Microphone",
                builtIn: transport == kAudioDeviceTransportTypeBuiltIn
            )
        }.sorted { lhs, rhs in
            if lhs.builtIn != rhs.builtIn { return lhs.builtIn }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &byteCount) == noErr && byteCount > 0
    }

    /// The system default input device, as Core Audio sees it right now.
    static var defaultInputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// True when the default input is the Mac's own microphone. Binding an audio graph to a
    /// Bluetooth headset switches it to the low-quality headset profile, which degrades whatever
    /// that headset is playing, so the warm-up must not bind while a headset is the default input.
    static var defaultInputIsBuiltIn: Bool {
        guard let device = defaultInputDevice else { return true }
        return propertyUInt32(device, selector: kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
    }

    static var defaultInputName: String {
        guard let device = defaultInputDevice else { return "unknown" }
        return propertyString(device, selector: kAudioObjectPropertyName) ?? "unknown"
    }

    private static func propertyUInt32(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &byteCount, &value) == noErr else { return nil }
        return value
    }

    private static func propertyString(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &byteCount, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
