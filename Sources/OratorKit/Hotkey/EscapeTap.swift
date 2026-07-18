import CoreGraphics
import Carbon.HIToolbox
import Foundation

/// A scoped `CGEvent` tap that swallows exactly the Escape key while recording (§11.4).
/// Created on record-start and torn down on stop — it is never live outside a dictation, which keeps
/// the privileged tap surface minimal.
///
/// If the tap cannot be created (Accessibility denied, or global secure input active), `start()`
/// returns false and the caller degrades to menu/indicator-click cancel (E10).
public final class EscapeTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var boxPtr: UnsafeMutableRawPointer?
    private let onEscape: @Sendable () -> Void

    public init(onEscape: @escaping @Sendable () -> Void) {
        self.onEscape = onEscape
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // Box the closure so the C callback (no captured context) can reach it.
        let boxObj = CallbackBox(onEscape)
        let box = Unmanaged.passRetained(boxObj).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.callback, userInfo: box
        ) else {
            Unmanaged<CallbackBox>.fromOpaque(box).release()
            Log.session.notice("Escape tap could not be created — degrading to menu cancel")
            return false
        }
        // Give the callback the port so it can re-enable itself on timeout (§11.4).
        boxObj.tap = tap
        self.tap = tap
        self.boxPtr = box
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let boxPtr { Unmanaged<CallbackBox>.fromOpaque(boxPtr).release() }   // no leak per dictation
        tap = nil
        runLoopSource = nil
        boxPtr = nil
    }

    private final class CallbackBox {
        let fn: @Sendable () -> Void
        // Set after tapCreate; used only on the run-loop thread to re-enable on timeout.
        nonisolated(unsafe) var tap: CFMachPort?
        init(_ fn: @escaping @Sendable () -> Void) { self.fn = fn }
    }

    // C-compatible callback. Swallows Escape (returns nil), re-enables on timeout, passes others.
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let box = Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable so Escape keeps working for the rest of the session (§11.4).
            if let tap = box.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
            box.fn()
            return nil   // swallow Escape (ORA-ACT-003)
        }
        return Unmanaged.passUnretained(event)
    }
}
