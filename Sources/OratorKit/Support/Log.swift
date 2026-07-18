import Foundation
import os

/// Central logging. Everything goes through the unified log (no files).
///
/// A debug log (transcripts + timings) exists ONLY behind an explicit, off-by-default developer
/// switch (ORA-MNT-002 / §9.8). It MUST NOT ship enabled; `DebugLog.isEnabled` defaults to `false`,
/// flipped only via the `OratorDebugLog` user default, never by product UI.
public enum Log {
    public static let session = Logger(subsystem: "com.grgmrr.orator", category: "session")
    public static let audio = Logger(subsystem: "com.grgmrr.orator", category: "audio")
    public static let speech = Logger(subsystem: "com.grgmrr.orator", category: "speech")
    public static let insert = Logger(subsystem: "com.grgmrr.orator", category: "insert")
}

extension Duration {
    /// Milliseconds as a Double, for latency instrumentation.
    public var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

/// Off-by-default local debug log for accuracy/latency tuning (ORA-MNT-002, §9.8, ORA-PERF-004).
/// The only sanctioned feedback loop under the no-telemetry posture (ORA-PRIV-002).
public enum DebugLog {
    /// Gated on an explicit developer default. Absent key ⇒ disabled ⇒ nothing is written.
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "OratorDebugLog")
    }

    /// Records a per-stage latency sample (start / first-confirmed / stop→final / final→inserted).
    public static func stage(_ name: String, ms: Double) {
        guard isEnabled else { return }
        Log.session.debug("⏱ \(name, privacy: .public): \(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }

    /// Records a transcript sample. Marked `.private` so it never leaks in shipped-log captures
    /// even if the developer switch is left on by accident.
    public static func transcript(_ text: String) {
        guard isEnabled else { return }
        Log.speech.debug("📝 \(text, privacy: .private)")
    }
}
