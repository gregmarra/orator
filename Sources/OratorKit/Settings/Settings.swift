import Foundation
import Carbon.HIToolbox

/// A serialized hotkey chord (Carbon key code + Carbon modifier mask). Default: ⌥Space.
public struct HotkeyChord: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32   // Carbon modifier flags (optionKey, cmdKey, …)

    /// ⌥Space — the default. Does NOT bind fn/Globe (ORA-ACT-005).
    public static let defaultChord = HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
}

/// How Orator chooses its capture device (ORA-CAP-002). Exactly two states, by spec — there is
/// deliberately no pin-an-arbitrary-device-by-UID case. On the common machine (system default IS the
/// built-in) such a pin resolved to the same device as both other options, so it offered a choice
/// with one outcome; see the ORA-CAP-002 rationale in SPEC.md.
///
/// Resolution is re-evaluated at every record start, so `builtIn` is matched by CoreAudio transport
/// type each time — it stays "the built-in" across machines rather than freezing a UID.
public enum MicSelection: Codable, Equatable, Hashable, Sendable {
    /// Follow the system default input device (default; respects the user's mic choice, incl. clamshell). Recommended.
    case automatic
    /// Pin the built-in microphone (avoids low-bandwidth Bluetooth HFP paths; resolved by transport type,
    /// so it stays "the built-in" across machines rather than a frozen UID).
    case builtIn

    /// Compact persisted form: "automatic" | "builtIn".
    var storageValue: String {
        switch self {
        case .automatic: return "automatic"
        case .builtIn: return "builtIn"
        }
    }

    /// Anything unrecognized reads as `.automatic` — which also retires any `device:<uid>` value left
    /// by an older build, landing that install on the system default rather than a dead pin.
    init(storageValue raw: String) {
        switch raw {
        case "builtIn": self = .builtIn
        default: self = .automatic   // incl. "automatic", legacy "followDefault", and retired "device:<uid>"
        }
    }
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
        static let micPolicy = "MicPolicy"       // legacy; read-only for migration into micSelection
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

    /// Reads the legacy "MicPolicy" key too, so an existing install's `followDefault`/`builtIn` choice
    /// carries over (ORA-CFG-002).
    public var micSelection: MicSelection {
        get { MicSelection(storageValue: defaults.string(forKey: Key.micSelection)
                            ?? defaults.string(forKey: Key.micPolicy) ?? "automatic") }
        set { defaults.set(newValue.storageValue, forKey: Key.micSelection) }
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
