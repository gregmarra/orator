import SwiftUI
import AppKit

/// Fixed indicator dimensions. The notch panel is barely wider than the physical notch; its content
/// sits BELOW the opaque camera housing (ORA-IND-011) in a compact chin (leading orb, preview tail,
/// timer). Size is fixed at record-start (ORA-IND-012).
public enum IndicatorMetrics {
    public static let barCount = 6                    // narrow leading waveform
    /// Consistent inset inside the panel's black edge (8-pt grid).
    public static let inset: CGFloat = 8
    /// Tighter than `inset`: the text line box reserves descender space, so a full `inset` here reads
    /// as MORE bottom margin than the equal sides. Trimming ~3 pt matches the visual gap.
    public static let bottomInset: CGFloat = 5
    public static let rowHeight: CGFloat = 18         // one content line (fits the 16-pt waveform + type)
    public static let contentHeight: CGFloat = rowHeight + inset + bottomInset   // chin band = 8 + row + 5
    public static let notchWidth: CGFloat = 300       // compact — barely wider than the notch
    public static let pillWidth: CGFloat = notchWidth  // matches the notch width so both fit the same preview
    public static let pillHeight: CGFloat = 36
    // Corner radii taken literally from the physical notch: 4 pt top, 8 pt bottom.
    public static let flareRadius: CGFloat = 4        // concave top corners → smooth into the bar
    public static let chinRadius: CGFloat = 8         // rounded bottom chin
    public static let defaultNotchBand: CGFloat = 32  // 14-inch notch height; live app uses the real one

    // MARK: Motion timelines (single source so paired animations can't drift)
    //
    // The notch expand/collapse spring (SwiftUI, `IndicatorRoot`) and the menu-bar tint crossfade
    // (CATransition, `StatusItemController`) fire TOGETHER at record start/end and must read as one
    // motion, so both derive their duration here. `IndicatorController`'s post-animation flush/teardown
    // delays derive from these too (duration + settle buffer) so a retimed spring can't strand them.
    public static let expandDuration: TimeInterval = 0.34    // spring OPEN (record start)
    public static let collapseDuration: TimeInterval = 0.28  // ease CLOSED (record end)
    /// Slack added after a spring so a follow-up (content flush, panel teardown) runs once it settles.
    public static let settleBuffer: TimeInterval = 0.02
    /// Delay before the orb morphs waveform→spinner, so a quick finalize/insert stays a flat waveform
    /// and the spinner appears only when processing genuinely drags.
    public static let spinnerActivationDelay: TimeInterval = 0.5

    public static func size(isNotch: Bool, notchBand: CGFloat = defaultNotchBand) -> CGSize {
        isNotch ? CGSize(width: notchWidth, height: notchBand + contentHeight)
                : CGSize(width: pillWidth, height: pillHeight)
    }
}

/// The notch silhouette: a flush full-width top whose corners curve outward and up back into the menu
/// bar (concave inverse corners, tangent to the bar), straight sides, and a rounded bottom chin — the
/// `\__/` the notch makes (ORA-IND-011). Every corner is tangent; radii mirror the hardware: flare
/// (top) vs chin (bottom).
struct NotchChinShape: Shape {
    var flare: CGFloat      // concave top corners that smooth into the bar
    var chin: CGFloat       // rounded bottom corners
    func path(in r: CGRect) -> Path {
        let t = flare, b = chin
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))                                   // top-left, at the bar (widest)
        // concave inverse corner: the horizontal bar line curves smoothly down into the left side.
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))                         // left side
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY)) // chin BL
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))                         // bottom
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY)) // chin BR
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))                         // right side
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))         // concave TR
        p.closeSubpath()                                                            // top edge back to start
        return p
    }
}

/// A compact live-level waveform. Plain SwiftUI shapes, not `Canvas`: the `Canvas` draw closure
/// crashes with an executor-isolation fault under the live animated hosting path on macOS 26
/// (EXC_BAD_ACCESS in `swift_task_isCurrentExecutor`); an `HStack` of capsules is safe and equivalent.
struct Waveform: View {
    let levels: [Float]
    let level: Float
    let color: Color
    /// Fixed by the single caller (`LeadingOrb`); no `GeometryReader` — reading size would force an
    /// extra layout pass every 100 ms level tick for a value that never changes.
    let size = CGSize(width: 22, height: 16)
    let bars = IndicatorMetrics.barCount

    var body: some View {
        let samples = normalizedSamples(count: bars)
        let slot = size.width / CGFloat(bars)
        HStack(spacing: 0) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: slot * 0.58, height: max(2, CGFloat(samples[i]) * size.height))
                    .frame(width: slot, height: size.height)   // centre each bar in its slot
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)   // decorative; state is announced by IndicatorController (IND-3)
    }

    private func normalizedSamples(count: Int) -> [Float] {
        var out = [Float](repeating: 0.15, count: count)
        if levels.isEmpty {
            for i in 0..<count {
                let phase = Float(i) / Float(count) * .pi * 3
                out[i] = 0.25 + 0.7 * max(level, 0.08) * abs(sin(phase))
            }
        } else {
            let recent = levels.suffix(count)
            let start = count - recent.count
            // Boost responsiveness: a compressive curve (pow < 1) lifts normal speech off the floor so
            // bars react visibly — tuned halfway between flat raw level and an aggressive boost, then
            // clamped at full height.
            for (j, v) in recent.enumerated() {
                out[start + j] = max(0.15, min(1, pow(max(0, v), 0.75) * 1.33))
            }
        }
        return out
    }
}

/// A white processing spinner (gapped rotating ring) — the finalizing/inserting state of the notch
/// leading orb. (The menu-bar icon stays a waveform; only the panel spins.)
struct SpinnerRing: View {
    var angle: Double
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(angle))
            .accessibilityHidden(true)   // decorative; state is announced by IndicatorController (IND-3)
    }
}

/// The leading "orb": a narrow orange waveform while recording, replaced by a white spinner while
/// finalizing/inserting (one slot: crossfade + scale + colour giving way to white). Deterministic when
/// `morph`/`clock` are provided (reel); otherwise self-driving (TimelineView + `.animation`) live.
struct LeadingOrb: View {
    var levels: [Float]
    var level: Float
    var spinning: Bool
    var morph: Double?
    var clock: Double?
    /// Reduce Motion (IND-2): crossfade by opacity only — no scale during the waveform↔spinner morph.
    var reduceMotion: Bool = false

    var body: some View {
        if let m = morph {                       // deterministic render (reel / stills)
            crossfade(morph: m, angle: ((clock ?? 0) / 0.9) * 360)
        } else {                                 // live
            // Pause the timeline while the spinner is hidden: don't re-render at display refresh rate
            // for the whole recording (battery); it ticks only while spinning.
            TimelineView(.animation(minimumInterval: nil, paused: !spinning)) { tl in
                let angle = (tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360
                crossfade(morph: spinning ? 1 : 0, angle: angle)
            }
            .animation(.easeInOut(duration: 0.35), value: spinning)
        }
    }

    private func crossfade(morph: Double, angle: Double) -> some View {
        // Leading-aligned: the spinner ring is narrower than the waveform; centering would push it past
        // the waveform's left edge (the 8pt margin), so align both to the leading edge.
        ZStack(alignment: .leading) {
            Waveform(levels: levels, level: level, color: Color(nsColor: .systemOrange))
                .opacity(1 - morph)
                .scaleEffect(reduceMotion ? 1 : 1 - 0.35 * morph)
            SpinnerRing(angle: angle)
                .opacity(morph)
                .scaleEffect(reduceMotion ? 1 : 0.6 + 0.4 * morph, anchor: .leading)
        }
        .frame(width: 22, height: 16, alignment: .leading)
    }
}

/// The indicator content, a pure function of `IndicatorContent` (§10.2, §11.2).
public struct IndicatorView: View {
    public let content: IndicatorContent
    private let increaseContrast: Bool
    private let reduceMotion: Bool
    private let reduceTransparency: Bool

    public init(content: IndicatorContent,
                increaseContrast: Bool = false, reduceMotion: Bool = false,
                reduceTransparency: Bool = false) {
        self.content = content
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }


    public var body: some View {
        let size = IndicatorMetrics.size(isNotch: content.isNotch, notchBand: content.notchBand)
        ZStack {
            background
            layout
        }
        .frame(width: size.width, height: size.height)
        .clipShape(clipShape)
        .overlay {
            if increaseContrast { clipShape.stroke(Color.white.opacity(0.9), lineWidth: 1) }
        }
        .environment(\.colorScheme, .dark)   // the panel is always dark (§10.4)
    }

    @ViewBuilder private var layout: some View {
        let ins = IndicatorMetrics.inset
        if content.isNotch {
            VStack(spacing: 0) {
                Color.clear.frame(height: content.notchBand)     // reserve the opaque notch band
                // 8 px inside the black edge on every side. Horizontal padding clears the concave flare
                // inset so the margin is measured from the black edge, not the frame.
                row.frame(height: IndicatorMetrics.rowHeight)
                    .padding(.top, ins).padding(.bottom, IndicatorMetrics.bottomInset)
                    .padding(.horizontal, IndicatorMetrics.flareRadius + ins)
            }
        } else {
            row.frame(height: IndicatorMetrics.pillHeight - ins * 2)
                .padding(.vertical, ins)
                .padding(.horizontal, IndicatorMetrics.pillHeight / 2 - 4)   // clear the capsule's round ends
        }
    }

    private var row: some View {
        // Baseline-align the text columns so the monospaced timer shares the preview text's baseline;
        // the non-text leading waveform is nudged so its optical center lands on the text's cap-height
        // center — reading as on the same line as the transcription.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            leading.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            center
            Spacer(minLength: 4)
            trailing
        }
    }

    @ViewBuilder private var background: some View {
        if content.isNotch {
            // Fully opaque black: the NOTCH panel must merge with the true-black (rgb 0) opaque camera
            // housing — any translucency seams against it on light wallpapers (ORA-IND-011a). Glass is
            // never correct here.
            clipShape.fill(Color.black)
        } else if reduceTransparency {
            // Accessibility fallback (ORA-A11Y-001): a solid dark capsule instead of glass.
            clipShape.fill(Color.black.opacity(0.9))
        } else {
            // The floating PILL sits over arbitrary desktop content, so it gets Liquid Glass (idiomatic
            // macOS 26 for a free-floating element, HIG review IND-2). Dark-tinted so white content
            // stays legible over any wallpaper.
            clipShape.fill(.clear)
                .glassEffect(.regular.tint(Color.black.opacity(0.45)), in: Capsule())
        }
    }

    private var clipShape: AnyShape {
        content.isNotch
            ? AnyShape(NotchChinShape(flare: IndicatorMetrics.flareRadius, chin: IndicatorMetrics.chinRadius))
            : AnyShape(Capsule())
    }

    // MARK: Leading orb (waveform ↔ spinner), or a warning glyph when not ready

    private var leading: some View {
        LeadingOrb(levels: content.levels, level: content.level,
                   spinning: content.spinnerActive, morph: content.morph, clock: content.staticClock,
                   reduceMotion: reduceMotion)
    }

    /// One muted style shared by the placeholder ("Listening") and the timer, keeping the palette
    /// minimal: white text, the orange waveform, and this single muted white.
    private var mutedStyle: Color { .white.opacity(increaseContrast ? 1.0 : 0.7) }

    // MARK: Center — short preview tail (recording) or the status label

    @ViewBuilder private var center: some View {
        if content.state == .recording {
            Text(content.previewTail.isEmpty ? content.statusLabel : content.previewTail)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(content.previewTail.isEmpty ? mutedStyle : Color.white)
                .lineLimit(1).truncationMode(.head)
        } else {
            // Finalizing/inserting status label — transient status, not content → muted style.
            Text(content.statusLabel)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(mutedStyle)
                .lineLimit(1)
        }
    }

    // MARK: Trailing — elapsed time

    @ViewBuilder private var trailing: some View {
        if content.state != .idle {
            Text(content.elapsedString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(mutedStyle)
                .monospacedDigit()
        }
    }
}

/// Observable holder so the live indicator animates state changes in place (orb morph, waveform, label
/// crossfade) rather than snapping when the hosting root view is replaced.
@MainActor @Observable
public final class IndicatorModel {
    public var content: IndicatorContent
    /// Drives the physical expand/collapse: content scales vertically from the top (out of the notch)
    /// on appear and collapses back in on dismiss, with spring physics.
    public var expanded: Bool = false
    public init(_ content: IndicatorContent) { self.content = content }
}

/// Live root: renders `IndicatorView` from an observable model and animates state transitions.
public struct IndicatorRoot: View {
    @Bindable var model: IndicatorModel
    let increaseContrast: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool

    public init(model: IndicatorModel, increaseContrast: Bool,
                reduceMotion: Bool = false, reduceTransparency: Bool = false) {
        self._model = Bindable(model)
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    public var body: some View {
        let indicator = IndicatorView(content: model.content,
                                      increaseContrast: increaseContrast,
                                      reduceMotion: reduceMotion,
                                      reduceTransparency: reduceTransparency)
        if reduceMotion {
            // Reduce Motion (IND-2 / ORA-IND-017): opacity-only — no spring expand, no scale. State
            // changes crossfade with a plain ease; appear/dismiss is a simple fade at final size.
            indicator
                .animation(.easeInOut(duration: 0.35), value: model.content.state)
                .opacity(model.expanded ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: model.expanded)
        } else {
            indicator
                .animation(.smooth(duration: 0.35), value: model.content.state)
                // Expand out of the notch: scale from a point at top-CENTER so it grows BOTH outward and
                // downward at once — the notch appears to stretch open rather than drop at full width
                // (which would expose the hardware notch).
                // DIRECTIONAL: expand `.snappy` (characterful spring overshoot); collapse `.smooth` (NO
                // overshoot) — on the way in, overshoot would happen up behind the opaque notch where
                // it's invisible, so it only costs smoothness (ORA-IND-011).
                .scaleEffect(model.expanded ? 1 : 0.12, anchor: .top)
                .opacity(model.expanded ? 1 : 0)
                .animation(model.expanded ? .snappy(duration: IndicatorMetrics.expandDuration)
                                          : .smooth(duration: IndicatorMetrics.collapseDuration),
                           value: model.expanded)
        }
    }
}
