import Foundation
import Observation

/// Why a dictation result landed in the recovery buffer (drives the menu subtitle, §10.3).
public enum RecoveryReason: Equatable, Sendable {
    case inserted             // went in cleanly; kept briefly so the user can re-copy
    case focusChanged         // frontmost app changed before insert (ORA-INS-002 / E8)
    case secureField          // target was a secure field (ORA-INS-007 / E9)
    case finalizationTimeout  // unfinalized tail parked past the cap (ORA-ASR-003 / E7)
    case noTarget             // no editable target / insertion failed outright
    case accessibilityMissing // insertion needs Accessibility, not granted (E2)

    public var label: String {
        switch self {
        case .inserted: return "Inserted"
        case .focusChanged: return "Focus changed — not inserted"
        case .secureField: return "Secure field — not inserted"
        case .finalizationTimeout: return "Finalized late — not inserted"
        case .noTarget: return "No text field — not inserted"
        case .accessibilityMissing: return "Accessibility off — not inserted"
        }
    }
}

/// One recoverable result. `text` is a `var` so it can be overwritten on expiry (ORA-REC-003).
public struct RecoveryEntry: Identifiable, Sendable {
    public let id: UUID
    public fileprivate(set) var text: String
    public let createdAt: Date
    public let reason: RecoveryReason

    /// A compact single-line menu label: the reason + a snippet of the text.
    public var menuTitle: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let snippet = flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
        return "\(reason.label): \(snippet)"
    }
}

/// In-memory, time-limited list of recent dictation results (§8.7).
///
/// - Hard 5-minute TTL, enforced by a timer that runs independently of user activity
///   (entries expire even if the menu is never opened) — ORA-REC-003.
/// - Bounded to `maxEntries` regardless of TTL (ORA-REC-006).
/// - Never written to disk by Orator (ORA-REC-005). Copy path is concealed (ORA-REC-002 → ORA-INS-005).
@MainActor
@Observable
public final class RecoveryBuffer {
    public static let ttl: TimeInterval = 5 * 60
    public static let maxEntries = 10

    public private(set) var entries: [RecoveryEntry] = []

    private let now: @MainActor () -> Date
    private var sweepTimer: Timer?

    /// `now` is injectable so tests can drive expiry without wall-clock waits.
    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    /// Insert a new result at the front. Cancelled sessions MUST NOT call this (ORA-SM-012).
    public func add(_ text: String, reason: RecoveryReason) {
        guard !text.isEmpty else { return }
        entries.insert(RecoveryEntry(id: UUID(), text: text, createdAt: now(), reason: reason), at: 0)
        // Enforce the count bound, overwriting the strings we drop.
        while entries.count > Self.maxEntries {
            overwrite(&entries[entries.count - 1])
            entries.removeLast()
        }
        scheduleNextSweep()
    }

    /// Copy an entry's text to the pasteboard, marked concealed (ORA-REC-002 / ORA-INS-005).
    public func copyToPasteboard(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        Pasteboard.writeConcealed(entry.text)
    }

    /// Remove entries older than the TTL and release their backing strings. Safe to call directly
    /// (tests drive it with an injected clock).
    public func sweep() {
        defer { scheduleNextSweep() }   // re-arm for whatever is still alive
        let cutoff = now().addingTimeInterval(-Self.ttl)
        guard entries.contains(where: { $0.createdAt < cutoff }) else { return }
        // Scrub stored strings in place (not loop copies) before dropping the entries.
        for i in entries.indices where entries[i].createdAt < cutoff {
            overwrite(&entries[i])   // ORA-REC-003: overwrite on removal
        }
        entries.removeAll { $0.createdAt < cutoff }
    }

    /// Arm a one-shot timer for the oldest entry's expiry; no timer while the buffer is empty
    /// (ORA-RES-001: no always-on polling). Expiry happens regardless of user activity (ORA-REC-003):
    /// the run loop fires even if the menu never opens. Fire delay is floored at 1 s so a
    /// stale/injected clock can't busy-loop the run loop.
    private func scheduleNextSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        guard let oldest = entries.map(\.createdAt).min() else { return }
        let delay = max(oldest.addingTimeInterval(Self.ttl).timeIntervalSince(now()), 1.0)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }                    // self gone ⇒ one-shot just expires
            MainActor.assumeIsolated { self.sweep() }         // fires on the main run loop
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    /// Best-effort scrub before the entry is dropped: Swift strings are copy-on-write value types
    /// we can't portably zero, so replace with "" to drop the last retain (ORA-REC-003 intent).
    private func overwrite(_ entry: inout RecoveryEntry) {
        entry.text = ""
    }
}
