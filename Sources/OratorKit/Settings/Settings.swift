import Foundation
import Carbon.HIToolbox

/// A serialized hotkey chord (Carbon key code + Carbon modifier mask). Default: ⌥Space.
public struct HotkeyChord: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32   // Carbon modifier flags (optionKey, cmdKey, …)

    /// ⌥Space — the default. Does NOT bind fn/Globe (ORA-ACT-005).
    public static let defaultChord = HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    /// Whether this chord is safe to claim system-wide. A plain key — or one with only ⇧ — would be
    /// taken from every app (a stray "a" in the recorder made "a" untypeable, across relaunches), so
    /// it needs ⌘, ⌥ or ⌃. Function keys are the exception: nothing types them.
    public var isUsableGlobally: Bool {
        let blocking = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        return modifiers & blocking != 0 || Self.functionKeys.contains(Int(keyCode))
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}

/// How Orator chooses its capture device (ORA-CAP-002). Exactly two states, by spec — there is
/// deliberately no pin-an-arbitrary-device-by-UID case. On the common machine (system default IS the
/// built-in) such a pin resolved to the same device as both other options, so it offered a choice
/// with one outcome; see the ORA-CAP-002 rationale in SPEC.md.
///
/// Resolution is re-evaluated at every record start, so `builtIn` is matched by CoreAudio transport
/// type each time — it stays "the built-in" across machines rather than freezing a UID.
public enum MicSelection: String, Codable, Equatable, Hashable, Sendable {
    /// Follow the system default input device (default; respects the user's mic choice, incl. clamshell). Recommended.
    case automatic
    /// Pin the built-in microphone (avoids low-bandwidth Bluetooth HFP paths; resolved by transport type,
    /// so it stays "the built-in" across machines rather than a frozen UID).
    case builtIn
}

/// UserDefaults-backed settings with an explicit, defaulted schema (ORA-CFG-002).
///
/// Product surface is ≤ 8 controls (M5 / ORA-CFG-001): hotkey, mic policy, locale, launch-at-login,
/// sound on/off. No per-app profiles (ORA-CFG-004).
@MainActor
public final class Settings {
    public static let shared = Settings()

    private let defaults: UserDefaults
    private enum Key {
        static let hotkey = "Hotkey"
        static let micSelection = "MicSelection"
        static let localeIdentifier = "LocaleIdentifier"
        static let soundEnabled = "SoundEnabled"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Controls (each with an explicit default)

    public var hotkey: HotkeyChord {
        get {
            guard let data = defaults.data(forKey: Key.hotkey),
                  let chord = try? JSONDecoder().decode(HotkeyChord.self, from: data)
            else { return .defaultChord }
            return chord
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.hotkey) }
    }

    /// Anything unrecognized reads as `.automatic` — which also retires any `device:<uid>` value left
    /// by an older build, landing that install on the system default rather than a dead pin.
    public var micSelection: MicSelection {
        get { defaults.string(forKey: Key.micSelection).flatMap(MicSelection.init(rawValue:)) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: Key.micSelection) }
    }

    public var localeIdentifier: String {
        get { defaults.string(forKey: Key.localeIdentifier) ?? "en-US" }  // English v1 (ORA-ASR-008)
        set { defaults.set(newValue, forKey: Key.localeIdentifier) }
    }

    public var soundEnabled: Bool {
        get { defaults.object(forKey: Key.soundEnabled) as? Bool ?? true }  // default on (ORA-FBK-001)
        set { defaults.set(newValue, forKey: Key.soundEnabled) }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }
}
