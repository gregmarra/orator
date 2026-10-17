import Carbon.HIToolbox

/// Global toggle hotkey via Carbon `RegisterEventHotKey` (ORA-ACT-002 / §11.4). Carbon: needs no
/// TCC permission and is robust against the secure-input and event-tap failure modes that afflict
/// CGEvent taps (§13 R5). Toggle only — no push-to-talk (ORA-ACT-001).
public final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: @Sendable () -> Void

    public init(onFire: @escaping @Sendable () -> Void) {
        self.onFire = onFire
    }

    /// Register (or re-register) the chord. Safe to call repeatedly (e.g. after a settings change).
    /// Returns false when the system refused it — typically another app already owns the chord.
    @discardableResult
    public func register(_ chord: HotkeyChord) -> Bool {
        unregister()
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524154 /* 'ORAT' */), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            Log.session.error("RegisterEventHotKey failed: \(status)")
            return false
        }
        hotKeyRef = ref
        return true
    }

    public func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), Self.handler, 1, &spec, context, &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private static let handler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        manager.onFire()
        return noErr
    }
}
