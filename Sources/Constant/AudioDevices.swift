import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannels: Int
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func outputDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0,
                  let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id)
            else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, outputChannels: channels)
        }
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    static func setBufferSize(_ frames: UInt32, on device: AudioDeviceID) {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &current)
        guard current != frames else { return }
        var value = frames
        AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value)
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
