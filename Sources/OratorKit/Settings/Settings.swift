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
///
/// Resolution is re-evaluated at every record start, so a pinned device is *sticky*: if it's absent
/// we fall back to the system default, and when it reappears we use it again — no relatch needed,
/// because the preference is stored by UID, not by a one-time device handle.
public enum MicSelection: Codable, Equatable, Hashable, Sendable {
    /// Follow the system default input device (default; respects the user's mic choice, incl. clamshell). Recommended.
    case automatic
    /// Pin the built-in microphone (avoids low-bandwidth Bluetooth HFP paths; resolved by transport type,
    /// so it stays "the built-in" across machines rather than a frozen UID).
    case builtIn
    /// Pin a specific device by its Core Audio UID. Sticky: falls back to `automatic` when absent.
    case device(uid: String)

    /// Compact persisted form: "automatic" | "builtIn" | "device:<uid>".
    var storageValue: String {
        switch self {
        case .automatic: return "automatic"
        case .builtIn: return "builtIn"
        case .device(let uid): return "device:\(uid)"
        }
    }

    init(storageValue raw: String) {
        switch raw {
        case "automatic", "followDefault": self = .automatic   // "followDefault" = migrated old MicPolicy
        case "builtIn": self = .builtIn
        default:
            if raw.hasPrefix("device:") { self = .device(uid: String(raw.dropFirst("device:".count))) }
            else { self = .automatic }
        }
    }
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
        static let micPolicy = "MicPolicy"       // legacy; read-only for migration into micSelection
        static let micSelection = "MicSelection"
        static let deviceNames = "DeviceNames"   // uid -> last-seen display name (for offline pins)
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

    /// Reads the legacy "MicPolicy" key too, so an existing install's `followDefault`/`builtIn` choice
    /// carries over (ORA-CFG-002).
    public var micSelection: MicSelection {
        get { MicSelection(storageValue: defaults.string(forKey: Key.micSelection)
                            ?? defaults.string(forKey: Key.micPolicy) ?? "automatic") }
        set { defaults.set(newValue.storageValue, forKey: Key.micSelection) }
    }

    /// Last-seen display name per device UID, so a pinned device that's currently unplugged can still
    /// be shown by name in the picker (ORA-CAP-009). Merges a whole enumeration in ONE read/write
    /// (not one dictionary rewrite per device), and writes only if something actually changed.
    public func rememberDeviceNames(_ names: [String: String]) {
        var map = defaults.dictionary(forKey: Key.deviceNames) as? [String: String] ?? [:]
        var changed = false
        for (uid, name) in names where map[uid] != name { map[uid] = name; changed = true }
        if changed { defaults.set(map, forKey: Key.deviceNames) }
    }

    public func rememberedDeviceName(for uid: String) -> String? {
        (defaults.dictionary(forKey: Key.deviceNames) as? [String: String])?[uid]
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
