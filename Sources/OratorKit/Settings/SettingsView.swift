import SwiftUI
import Carbon.HIToolbox

/// The single small settings pane (ORA-CFG-001). Exactly the sanctioned controls, ≤ 8 (M5):
/// hotkey, language, microphone policy, custom vocabulary, launch-at-login, sound.
/// No per-app profiles / workflow editor / model picker / plugins (ORA-CFG-004).
public struct SettingsView: View {
    @State private var hotkey: HotkeyChord = Settings.shared.hotkey
    @State private var micPolicy: MicPolicy = Settings.shared.micPolicy
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var soundEnabled: Bool = Settings.shared.soundEnabled
    @State private var vocabulary: [String] = Settings.shared.vocabulary
    @State private var newTerm: String = ""
    @State private var recordingHotkey = false
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
                Picker("Microphone", selection: $micPolicy) {
                    Text("System default").tag(MicPolicy.followDefault)
                    Text("Built-in microphone").tag(MicPolicy.builtIn)
                }
                .onChange(of: micPolicy) { _, v in Settings.shared.micPolicy = v }
                Toggle("Play start/stop sounds", isOn: $soundEnabled)
                    .onChange(of: soundEnabled) { _, v in Settings.shared.soundEnabled = v }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }

            Section {
                Button("Reset Setup and Permissions…", role: .destructive) { onReset?() }
            }

            // Vocabulary last: it grows as the user adds terms, so it never pushes the fixed controls;
            // the grouped Form scrolls this section internally within the fixed window (SET-5).
            Section {
                HStack {
                    TextField("Add a name or term…", text: $newTerm)
                        .textFieldStyle(.roundedBorder)   // HIG: an editable field needs a visible bezel
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(newTerm.isEmpty)
                }
                // Editable collection: an explicit remove button (discoverable on macOS) plus
                // `.onDelete` for keyboard/swipe delete (SET-4).
                ForEach(vocabulary, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button { vocabulary.removeAll { $0 == term } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(term)")
                    }
                }
                .onDelete { vocabulary.remove(atOffsets: $0) }
            } header: {
                Text("Custom vocabulary")
            } footer: {
                // Explanatory help text belongs in a section footer, not an inline caption row (SET-3).
                Text("Names, jargon, or product terms to bias recognition toward.")
            }
            // Persist on any change — the same idiom the other settings use above.
            .onChange(of: vocabulary) { _, v in Settings.shared.vocabulary = v }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 540)
        .task { await language.reload?() }   // read supported/installed locales dynamically on open
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

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !vocabulary.contains(term) else { return }
        vocabulary.append(term)
        newTerm = ""
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
