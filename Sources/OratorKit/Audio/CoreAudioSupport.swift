import Foundation
import CoreAudio

/// Minimal CoreAudio lookups for authoritative device identification and enumeration. AVFoundation's
/// audio device view on macOS is flakier and less complete than CoreAudio's (and exposes no
/// "is built-in" flag — macOS 14+ reports every mic as `.microphone`), so CoreAudio is the source of
/// truth for *which* input devices exist and how to tell them apart (transport type). We map a chosen
/// device to an `AVCaptureDevice` by UID for actual capture.
enum CoreAudioSupport {
    /// A selectable audio *input* device. `uid` is the stable Core Audio UID, which also equals the
    /// `AVCaptureDevice.uniqueID` for the same device, so it round-trips into `AVCaptureDevice(uniqueID:)`.
    struct InputDevice: Identifiable, Equatable, Sendable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    // MARK: Full enumeration (for the Settings list — NOT the record-start hot path)

    /// Every input device with at least one real input channel (garbage inputs — devices that expose
    /// no capturable channels — are dropped). O(devices) CoreAudio IPC + per-device name/CFString
    /// lookups; keep this off the hotkey→capture path (see the AudioDeviceList model / hot-path memory).
    static func inputDeviceList() -> [InputDevice] {
        deviceIDs().compactMap { dev -> InputDevice? in
            guard hasInputChannels(dev), let uid = deviceUID(dev) else { return nil }
            return InputDevice(uid: uid, name: deviceName(dev) ?? uid)
        }
    }

    // MARK: O(1) lookups (safe on the hot path)

    /// UID of the current system default *input* device, or nil. One property read.
    static func defaultInputUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceUID(dev)
    }

    /// UID of the built-in audio *input* device (transport type == Built-in), or nil if none.
    static func builtInInputUID() -> String? {
        for dev in deviceIDs() where hasInputChannels(dev) && transportType(dev) == kAudioDeviceTransportTypeBuiltIn {
            return deviceUID(dev)
        }
        return nil
    }

    /// Whether a device with this UID is currently present AND has capturable input channels — i.e.
    /// a live, non-garbage input. Used to decide if a pinned/default UID can actually be used before
    /// falling back. Resolves the UID to its device, then reads one channel-config property.
    static func isUsableInput(uid: String) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        return hasInputChannels(dev)
    }

    /// Register `block` for a system-object property change (global/main scope). Returns the address
    /// used — needed to remove the listener later — and the registration status. The single place the
    /// listener-registration boilerplate lives, so callers don't hand-build `AudioObjectPropertyAddress`.
    @discardableResult
    static func addSystemListener(_ selector: AudioObjectPropertySelector,
                                  on queue: DispatchQueue = .main,
                                  _ block: @escaping AudioObjectPropertyListenerBlock)
        -> (address: AudioObjectPropertyAddress, status: OSStatus) {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        return (addr, status)
    }

    // MARK: Private CoreAudio plumbing

    private static func deviceIDs() -> [AudioObjectID] {
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
        return ids
    }

    /// Resolve a Core Audio UID back to its live device ID via `kAudioHardwarePropertyTranslateUIDToDevice`
    /// (one translation call — no full enumeration).
    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &outSize, &dev)
        }
        guard status == noErr, dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return dev
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
        cfStringProperty(dev, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Human-readable device name (e.g. "MacBook Air Microphone", "Work USB Camera").
    private static func deviceName(_ dev: AudioObjectID) -> String? {
        cfStringProperty(dev, selector: kAudioObjectPropertyName)
    }

    private static func cfStringProperty(_ dev: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var str: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &str) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? str as String? : nil
    }
}
