import Foundation
import Carbon.HIToolbox

/// A serialized hotkey chord (Carbon key code + Carbon modifier mask). Default: ⌥Space.
public struct HotkeyChord: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32   // Carbon modifier flags (optionKey, cmdKey, …)

    /// ⌥Space — the default. Does NOT bind fn/Globe (ORA-ACT-005).
    public static let defaultChord = HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
}

/// How Orator chooses its capture device (ORA-CAP-002).
public enum MicPolicy: String, Codable, CaseIterable, Sendable {
    /// Follow the system default input device (default; respects the user's mic choice, incl. clamshell). Recommended.
    case followDefault
    /// Pin the built-in microphone (avoids low-bandwidth Bluetooth HFP paths; optional).
    case builtIn
}

/// UserDefaults-backed settings with an explicit, defaulted schema (ORA-CFG-002).
///
/// Product surface is ≤ 8 controls (M5 / ORA-CFG-001): hotkey, mic policy, locale, launch-at-login,
/// custom vocabulary, sound on/off. No per-app profiles (ORA-CFG-004).
@MainActor
public final class Settings {
    public static let shared = Settings()

    private let defaults: UserDefaults
    private enum Key {
        static let hotkey = "Hotkey"
        static let micPolicy = "MicPolicy"
        static let localeIdentifier = "LocaleIdentifier"
        static let vocabulary = "CustomVocabulary"
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

    public var micPolicy: MicPolicy {
        get { MicPolicy(rawValue: defaults.string(forKey: Key.micPolicy) ?? "") ?? .followDefault }
        set { defaults.set(newValue.rawValue, forKey: Key.micPolicy) }
    }

    public var localeIdentifier: String {
        get { defaults.string(forKey: Key.localeIdentifier) ?? "en-US" }  // English v1 (ORA-ASR-008)
        set { defaults.set(newValue, forKey: Key.localeIdentifier) }
    }

    /// Custom vocabulary terms that bias recognition (ORA-VOC-001/002).
    public var vocabulary: [String] {
        get { defaults.stringArray(forKey: Key.vocabulary) ?? [] }
        set { defaults.set(newValue, forKey: Key.vocabulary) }
    }

    public var soundEnabled: Bool {
        get { defaults.object(forKey: Key.soundEnabled) as? Bool ?? true }  // default on (ORA-FBK-001)
        set { defaults.set(newValue, forKey: Key.soundEnabled) }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }
}
