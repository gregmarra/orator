import Foundation
import CoreAudio

/// Minimal CoreAudio lookups for authoritative device identification. AVFoundation exposes no
/// "is built-in" flag for audio (macOS 14+ reports every mic as `.microphone`), so we read the
/// CoreAudio transport type — the reliable way to tell the built-in mic from a Continuity/Bluetooth
/// device that merely happens to be first in the list.
enum CoreAudioSupport {
    /// UID of the built-in audio *input* device (transport type == Built-in), or nil if none.
    static func builtInInputUID() -> String? {
        for dev in inputDevices() where transportType(dev) == kAudioDeviceTransportTypeBuiltIn {
            return deviceUID(dev)
        }
        return nil
    }

    private static func inputDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter { hasInputChannels($0) }
    }

    private static func hasInputChannels(_ dev: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, bufferList) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.contains { $0.mNumberChannels > 0 }
    }

    private static func transportType(_ dev: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value)
        return value
    }

    private static func deviceUID(_ dev: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? uid as String? : nil
    }
}
