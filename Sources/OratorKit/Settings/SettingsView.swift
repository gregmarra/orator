import SwiftUI
import Carbon.HIToolbox

/// The single small settings pane (ORA-CFG-001). Exactly the sanctioned controls, ≤ 8 (M5):
/// hotkey, language, microphone policy, launch-at-login, sound.
/// No per-app profiles / workflow editor / model picker / plugins (ORA-CFG-004).
public struct SettingsView: View {
    @State private var hotkey: HotkeyChord = Settings.shared.hotkey
    @State private var micSelection: MicSelection = Settings.shared.micSelection
    /// Live list of input devices; refreshes as mics are plugged/unplugged while Settings is open.
    /// Live input-level meter for the selected device (Settings-only; released on disappear).
    @State private var meter = MicLevelMonitor()
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var soundEnabled: Bool = Settings.shared.soundEnabled
    @State private var recordingHotkey = false
    /// Whether this window is the active/key window. The meter holds the microphone (orange indicator,
    /// battery, and a second session on the same device a recording might use), so we only run it while
    /// Settings is the frontmost window and pause it otherwise (ORA-CAP-010).
    @Environment(\.controlActiveState) private var controlActiveState
    @Bindable private var language: LanguageModel
    /// A not-yet-installed language the user picked, awaiting download confirmation.
    @State private var pendingInstallID: String?

    /// Invoked when the hotkey chord changes so the app can re-register it.
    public var onHotkeyChange: ((HotkeyChord) -> Void)?
    /// Invoked when the hotkey recorder becomes active/inactive. While active, the app MUST suspend
    /// the global hotkey so the user can press their current combo without it firing Orator.
    public var onHotkeyRecording: ((Bool) -> Void)?
    /// Invoked to run the setup reset (§4 scenario 6).
    public var onReset: (() -> Void)?

    public init(language: LanguageModel,
                onHotkeyChange: ((HotkeyChord) -> Void)? = nil,
                onHotkeyRecording: ((Bool) -> Void)? = nil,
                onReset: (() -> Void)? = nil) {
        self._language = Bindable(language)
        self.onHotkeyChange = onHotkeyChange
        self.onHotkeyRecording = onHotkeyRecording
        self.onReset = onReset
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    HotkeyField(chord: $hotkey, recording: $recordingHotkey) { chord in
                        Settings.shared.hotkey = chord
                        onHotkeyChange?(chord)
                    }
                    .onChange(of: recordingHotkey) { _, active in onHotkeyRecording?(active) }
                }
                languageRow
                micRow
                Toggle("Play start/stop sounds", isOn: $soundEnabled)
                    .onChange(of: soundEnabled) { _, v in Settings.shared.soundEnabled = v }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }

            Section {
                // Opens the guided setup window. NOT destructive and not a reset: the actual
                // (destructive) permission resets are per-step buttons inside that window. Labelling
                // this "Reset Setup and Permissions…" in red promised an irreversible revoke it never
                // performed, and simultaneously hid setup behind a button nobody wanting setup would press.
                Button("Open Setup…") { onReset?() }
            }
        }
        .formStyle(.grouped)
        // Fixed width (the single-pane Settings idiom), content-driven height. The height used to be
        // pinned at 540 so the vocabulary list could grow and scroll inside it; with that section
        // gone the constant only produced dead space. `fixedSize` vertically is what stops the
        // grouped Form's scroll view from claiming the space instead of reporting its ideal height.
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task { await language.reload?() }   // read supported/installed locales dynamically on open
        .onAppear { syncMeter() }
        .onDisappear { meter.stop() }
        // Only meter while this window is frontmost — pause when the user switches away or is dictating
        // into another app (so the mic isn't held, and we don't run a second session on it).
        .onChange(of: controlActiveState) { _, _ in syncMeter() }
    }

    /// Run the meter only while the window is active; stop it (releasing the mic) otherwise.
    private func syncMeter() {
        if controlActiveState == .inactive { meter.stop() } else { meter.start() }
    }

    /// Microphone picker: "Automatic" (follow the system default) or a pinned "Built-in" — those two
    /// only (ORA-CAP-002). A user whose preferred mic isn't the system default changes it in System
    /// Settings, where that choice already lives.
    @ViewBuilder private var micRow: some View {
        // Picker + level bar + status as ONE Form row, so no divider (horizontal rule) separates the
        // bar from the picker it belongs to.
        VStack(alignment: .leading, spacing: 8) {
        Picker("Microphone", selection: $micSelection) {
            Text("Automatic (system default)").tag(MicSelection.automatic)
            Text("Built-in microphone").tag(MicSelection.builtIn)
        }
        .onChange(of: micSelection) { _, v in
            Settings.shared.micSelection = v
            meter.restart()   // preview the newly-selected device immediately
        }

        // Level bar directly beneath the picker (same row, no rule), then a compact status line.
        // Combine them into one VoiceOver element so the spoken value carries BOTH the live level and
        // the resolved-device/error state (the bar alone would announce "0 percent" when silent —
        // indistinguishable from a dead mic) (ORA-CAP-021).
        VStack(alignment: .leading, spacing: 4) {
            LevelBar(level: meter.level)
            micStatus
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(micStatusText)
        }
    }

    /// Compact status under the level bar: the *effective* mode + resolved device, e.g.
    /// "Automatic (MacBook Air Microphone)". Middle-truncates when it doesn't fit, so both the mode and
    /// the tail of the device name stay visible. Also covers the can't-open and no-device states.
    @ViewBuilder private var micStatus: some View {
        Text(micStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Status line — the decision itself lives in `MicStatus` so it is unit-testable.
    private var micStatusText: String {
        MicStatus.text(permissionDenied: meter.permissionDenied,
                       openFailure: meter.openFailure,
                       resolvedName: meter.resolvedName,
                       selection: micSelection,
                       substituted: meter.substituted,
                       clipping: meter.clipping)
    }

    /// Language picker built from the transcriber's supported locales (dynamic). Selecting a language
    /// whose model isn't installed triggers the OS download, shown inline below the picker.
    @ViewBuilder private var languageRow: some View {
        Picker("Language", selection: $language.selectedID) {
            ForEach(language.options, id: \.self) { id in
                Text(language.displayName(id)).tag(id)
            }
        }
        .disabled(language.options.isEmpty || language.downloadingID != nil)
        .onChange(of: language.selectedID) { _, id in
            guard id != language.appliedID else { return }
            if language.isInstalled(id) {
                Task { await language.select?(id) }      // already on-device → switch immediately
            } else {
                pendingInstallID = id                    // needs a download → confirm first
            }
        }
        // Confirm before a model download; cancel reverts the picker.
        .alert("Download the \(language.displayName(pendingInstallID ?? "")) model from Apple?",
               isPresented: Binding(get: { pendingInstallID != nil },
                                    set: { if !$0 { pendingInstallID = nil } })) {
            Button("Download") {
                if let id = pendingInstallID { Task { await language.select?(id) } }
                pendingInstallID = nil
            }
            Button("Cancel", role: .cancel) {
                language.selectedID = language.appliedID   // revert the picker
                pendingInstallID = nil
            }
        } message: {
            // Apple's asset API never reports size (progress is a normalized fraction); measured models are ~340–380 MB, so ~350 MB is honest.
            Text("Language models are about 350 MB. Once downloaded, transcription runs locally on your Mac.")
        }

        if let downloading = language.downloadingID {
            // Active install of the just-picked language.
            ProgressView(value: language.progress) {
                Text("Downloading \(language.displayName(downloading))…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let err = language.errorText {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        } else if !language.isInstalled(language.selectedID), !language.options.isEmpty {
            // Selected but not yet on-device (e.g. state right before a retry).
            Text("\(language.displayName(language.selectedID)) will download when selected.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

}

/// A slim horizontal input-level meter (0…1). Theme-aware via `.tint`/`.quaternary`; the level is
/// smoothed upstream, so the tiny linear animation just removes sub-frame jitter.
struct LevelBar: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(min(1, max(0, level)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityLabel("Input level")
        // Coarse buckets (not a live percentage) so a ~30 Hz value doesn't spam VoiceOver; the
        // .updatesFrequently trait tells VoiceOver to re-read on demand rather than announce churn.
        .accessibilityValue(Self.levelWord(level))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private static func levelWord(_ level: Float) -> String {
        switch min(1, max(0, level)) {
        case ..<0.05: return "silent"
        case ..<0.35: return "low"
        case ..<0.70: return "medium"
        default:      return "high"
        }
    }
}

/// A minimal hotkey recorder: click to capture the next chord.
struct HotkeyField: View {
    @Binding var chord: HotkeyChord
    @Binding var recording: Bool
    var onChange: (HotkeyChord) -> Void

    var body: some View {
        // Click to enter "set" mode. Capture view mounts ONLY while recording — never steals key events
        // until asked — and grabs focus synchronously on mount (no async first-responder juggling).
        Button(recording ? "Press a key…  (Esc to cancel)" : describe(chord)) { recording = true }
            .buttonStyle(.bordered)
            .overlay {
                if recording {
                    KeyCaptureView(
                        onCapture: { newChord in chord = newChord; recording = false; onChange(newChord) },
                        onCancel: { recording = false })
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
            }
    }

    private func describe(_ c: HotkeyChord) -> String {
        var s = ""
        if c.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if c.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if c.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if c.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyNames.name(for: c.keyCode)
        return s
    }
}

/// Bridges an NSView first-responder key capture into SwiftUI for the recorder. Mounted only while
/// recording; grabs focus synchronously in `viewDidMoveToWindow` (no async, no non-Sendable capture).
struct KeyCaptureView: NSViewRepresentable {
    var onCapture: (HotkeyChord) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let v = CaptureNSView()
        v.onCapture = onCapture
        v.onCancel = onCancel
        return v
    }
    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
    }

    final class CaptureNSView: NSView {
        var onCapture: ((HotkeyChord) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)   // grab focus when mounted (only happens while recording)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) { onCancel?(); return }   // Esc cancels
            let carbonMods = Self.carbonModifiers(event.modifierFlags)
            onCapture?(HotkeyChord(keyCode: UInt32(event.keyCode), modifiers: carbonMods))
        }
        static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
            var m: UInt32 = 0
            if flags.contains(.control) { m |= UInt32(controlKey) }
            if flags.contains(.option) { m |= UInt32(optionKey) }
            if flags.contains(.shift) { m |= UInt32(shiftKey) }
            if flags.contains(.command) { m |= UInt32(cmdKey) }
            return m
        }
    }
}

enum KeyNames {
    /// Keys UCKeyTranslate renders as control/whitespace characters get real names (HIG SET-2).
    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    static func name(for keyCode: UInt32) -> String {
        special[Int(keyCode)] ?? layoutName(for: keyCode) ?? "Key \(keyCode)"
    }

    /// Translate a virtual key code to its character in the CURRENT keyboard layout, so the hotkey
    /// reads correctly on non-ANSI/US layouts (HIG SET-2). Returns nil for keys with no printable
    /// character (function keys, etc.), which fall back to "Key N".
    private static func layoutName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,   // no modifiers
                UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let name = String(utf16CodeUnits: chars, count: length)
            guard !name.isEmpty,
                  !name.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
                  })
            else { return nil }
            return name.uppercased()
        }
    }
}
