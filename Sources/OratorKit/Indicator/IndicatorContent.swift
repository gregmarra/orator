import Foundation

/// A pure, `Equatable` snapshot that the indicator view renders as a function of. Keeping the view
/// a pure function of this value makes it deterministically renderable off-screen (the visual
/// verification path, AC-7/AC-8) and keeps AppKit sizing out of SwiftUI (ORA-IND-012).
public struct IndicatorContent: Sendable, Equatable {
    public var state: SessionState
    public var elapsed: TimeInterval
    /// Current audio level 0…1 (most recent).
    public var level: Float
    /// Recent audio levels for the waveform, oldest→newest (drives the bar heights).
    public var levels: [Float]
    /// The tail of the live text (confirmed + volatile). Single-line, truncated to the tail.
    public var previewTail: String
    /// Notch treatment when true; pill when false (ORA-IND-014/015).
    public var isNotch: Bool
    /// Height (points) of the opaque physical-notch band at the top of a notch panel. Content is laid
    /// out BELOW this so the camera housing never occludes it (ORA-IND-011). 0 for the pill.
    public var notchBand: CGFloat

    /// Deterministic-render overrides for the leading orb, used by the reel/still harnesses so the
    /// waveform→spinner morph renders frame-by-frame. In the live app both are nil and the view
    /// drives itself (TimelineView for the spin, `.animation` for the morph).
    public var morph: Double?         // 0 = waveform, 1 = spinner
    public var staticClock: Double?   // seconds, drives the spinner rotation deterministically

    /// Live-path gate for the leading-orb morph: set true only after processing runs > 500 ms
    /// (rationale on `IndicatorMetrics.spinnerActivationDelay`). Ignored when `morph` is set (harness path).
    public var spinnerActive: Bool = false

    /// A terminal outcome message held briefly after the session ends (text saved to the menu, nothing
    /// heard, mic lost). When set it REPLACES the status label, so a non-success outcome is visible
    /// rather than collapsing exactly like a success.
    public var notice: String?

    public init(state: SessionState, elapsed: TimeInterval,
                level: Float, levels: [Float] = [], previewTail: String,
                isNotch: Bool, notchBand: CGFloat? = nil,
                morph: Double? = nil, staticClock: Double? = nil,
                notice: String? = nil) {
        self.morph = morph
        self.staticClock = staticClock
        self.notice = notice
        self.state = state
        self.elapsed = elapsed
        self.level = level
        self.levels = levels
        self.previewTail = previewTail
        self.isNotch = isNotch
        // Default to the 14-inch physical notch height for off-screen rendering; the live controller
        // overrides with the real `safeAreaInsets.top`.
        self.notchBand = notchBand ?? (isNotch ? IndicatorMetrics.defaultNotchBand : 0)
    }

    /// Elapsed time as mm:ss (§10.1 "elapsed time counts up").
    public var elapsedString: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The verb-first status label (§10.3): name what's happening.
    public var statusLabel: String {
        switch state {
        case .idle: return "Ready"
        case .recording: return "Listening…"
        case .finalizing: return "Transcribing…"
        case .inserting: return "Inserting text…"
        }
    }
}
