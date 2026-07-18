import Foundation

/// Observable backing for the Settings **Language** control. The list of languages is read
/// dynamically from the on-device transcriber (`SpeechEngine.supportedLocaleIDs`) — nothing is
/// hard-coded — and selecting a language whose model isn't present triggers the OS model install
/// (ORA-ASR-006). The app layer supplies `reload`/`select`; the view only renders this state.
@MainActor @Observable
public final class LanguageModel {
    /// All BCP-47 locale ids the transcriber supports on this device, sorted by localized name.
    public var options: [String] = []
    /// BCP-47 ids whose model is already installed on-device.
    public var installedIDs: Set<String> = []
    /// The selected locale's BCP-47 id (what the picker shows — may be mid-confirmation).
    public var selectedID: String
    /// The locale the engine is actually committed to. `selectedID` reverts here if the user cancels
    /// a download or an install fails.
    public var appliedID: String
    /// The locale currently downloading (BCP-47), if any, and its progress 0…1.
    public var downloadingID: String?
    public var progress: Double = 0
    /// Legible failure for the last install attempt (retryable — never fatal, E4).
    public var errorText: String?

    /// Populate `options` / `installedIDs` from the transcriber. Set by the app layer.
    public var reload: (() async -> Void)?
    /// Switch to a locale, installing its model first if needed. Set by the app layer.
    public var select: ((String) async -> Void)?

    public init(selectedID: String) {
        self.selectedID = selectedID
        self.appliedID = selectedID
    }

    /// A human name for a BCP-47 id, localized to the user's SYSTEM language (e.g. "German (Germany)"
    /// for an English system), NOT the endonym ("Deutsch") — users read their system language, so those names scan best.
    public func displayName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    public func isInstalled(_ id: String) -> Bool { installedIDs.contains(id) }
}
