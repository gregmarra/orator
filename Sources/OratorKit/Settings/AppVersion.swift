import Foundation

/// The running build's fingerprint, shown at the bottom of the settings pane so a bug report — or a
/// "wait, is this the build with the fix?" — can name the exact binary it came from.
///
/// Every field is read from the app bundle's `Info.plist`, which `Scripts/bundle.sh` stamps from git
/// at assembly time. The alternative, generating a Swift constant holding the hash, was rejected: it
/// dirties a source file on every commit (and every `git stash`), so it invalidates the incremental
/// build for a string nothing computes with. The plist is also where macOS itself already looks —
/// Finder's Get Info, crash reports, and any future updater all read the same two keys.
public enum AppVersion {

    /// Marketing version (`CFBundleShortVersionString`). Hand-edited in `Resources/Info.plist`; it is
    /// the one part of the fingerprint a human chooses.
    public static var marketing: String { value("CFBundleShortVersionString") ?? "—" }

    /// Build number (`CFBundleVersion`): the repo's commit count at assembly time. Monotonic, which is
    /// what every updater and macOS's own "is this newer" comparison require.
    public static var build: String? { value("CFBundleVersion") }

    /// Short commit hash, suffixed `-dirty` when assembled from an unclean working tree.
    public static var revision: String? { value("ORAGitRevision") }

    /// UTC assembly timestamp. Not shown inline — it is what disambiguates two different `-dirty`
    /// builds of the same commit, so it lives in the footer's tooltip.
    public static var buildDate: String? { value("ORABuildDate") }

    /// One line for the settings footer, e.g. `Orator 1.0 (30) · 8cea807`. Degrades a piece at a time:
    /// a build run straight out of SwiftPM (or a unit test, where `Bundle.main` is the test runner)
    /// has no stamped keys and simply shows less.
    public static var displayString: String {
        var line = "Orator \(marketing)"
        if let build { line += " (\(build))" }
        if let revision { line += " · \(revision)" }
        return line
    }

    /// Non-empty string for `key`, or nil. Treats the un-stamped placeholder as absent so an
    /// unstamped bundle shows nothing rather than the word "unknown".
    private static func value(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty || trimmed == "unknown") ? nil : trimmed
    }
}
