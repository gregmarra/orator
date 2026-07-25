# Orator — Product & Engineering Specification

**Version:** 1.0 · **Platform:** macOS 26+ (Apple Silicon)

---

## 0. Conventions

Requirement keywords follow RFC 2119: **MUST** / **MUST NOT** (mandatory), **SHOULD** / **SHOULD NOT**
(strong default, deviation must be justified), **MAY** (optional). Every normative requirement carries a
stable identifier `ORA-<AREA>-<NNN>`. Non-normative material (rationale, code sketches, examples) is
clearly marked and never uses RFC-2119 keywords.

---

## 1. Purpose & Vision

**Orator is a menu-bar dictation utility for macOS.** You press a keyboard shortcut, speak for as long as you like,
press the keyboard shortcut again, and the words you spoke are placed into whatever text field you were using — quickly,
accurately, and entirely on-device.

It has exactly one job and does it without ceremony: **turn speech into text in the focused text field.**
It is not a note-taker, a transcription workstation, a meeting recorder, or an AI writing assistant. It is a
fast, private, native dictation key.

**The two things that matter above all else are performance and accuracy.** Every design decision is made in
their service first. Simplicity of the product surface and long-term maintainability come next, and are
treated as means to protect performance and accuracy (fewer moving parts, fewer regressions), not as ends
that trade against them.

---

## 2. Definitions & Glossary

| Term | Meaning |
|---|---|
| **Dictation** | A single recording→transcription→insertion cycle initiated and ended by the user. |
| **Session** | The runtime object representing one dictation, from start to insertion (or cancellation). |
| **Target field** | The focused, editable text element in the frontmost application at insertion time. |
| **Recognizer** | Apple's on-device speech analysis engine (the Speech framework's analyzer + transcriber). |
| **Confirmed / finalized text** | Recognition results the engine has committed and will not revise. |
| **Volatile text** | Provisional recognition results the engine may still revise before finalizing. |
| **Recovery buffer** | An in-memory, time-limited list of recent dictation results, for re-copying if insertion missed its target. |
| **Indicator** | The visible recording-state UI: a menu-bar item and (on capable displays) a notch panel. |
| **Warm** | State in which the recognizer instance, model, and audio graph are prepared so a dictation can begin with no setup latency. |
| **Cold** | The opposite: a first-use or post-unload state requiring setup or download before dictation can begin. |

---

## 3. Goals, Non-Goals, Success Metrics

### 3.1 Goals

- G1. Start dictating within one hotkey press (possibly a key with modifier keys, such as option + spacebar), with no perceptible startup delay.
- G2. On stop, place accurate text into the target field as fast as the platform allows.
- G3. Run 100% on-device; make no network request for any core function.
- G4. Present a minimal surface: one hotkey, one indicator, one small settings pane, one recovery list.
- G5. Never lose text the user spoke, even when insertion fails. 
- G6. Do not retain text longer than 10 minutes, outside of insertion.
- G7. Be maintainable by a single developer and installable by a non-technical friend.
- G8. Abortable. The user can press 'esc' to cancel with no text insertation.

### 3.2 Non-Goals (v1)

- N1. No cloud transcription, no cloud LLM, no accounts, no telemetry, no auto-update service.
- N2. No file/batch transcription, no audio recording/export, no meeting or system-audio capture.
- N3. No persistent transcript history, search, tagging, or export.
- N4. No text “commands” (e.g. spoken “new paragraph” as an editing command beyond native punctuation).
- N5. No multi-app “profiles,” no per-app configuration surface beyond what insertion reliability requires.
- N6. No plugin system, no alternate speech engines, no engine selection UI.
- N7. No on-device LLM post-processing in v1 (see §17 for the deferred opt-in).

### 3.3 Success Metrics

| Metric | Target |
|---|---|
| **M1. Start latency** — hotkey press → audio being captured & indicator visible (warm) | ≤ 50 ms |
| **M2. Stop latency (typical)** — hotkey press-to-stop → text present in target field, for a ≤ 30 s dictation | ≤ 500 ms |
| **M3. Finalization cap** — worst-case wait for the engine to flush confirmed text on stop before Orator degrades gracefully | ≤ 2500 ms |
| **M4. Text-loss incidents** — dictated speech irrecoverable after a failed insertion | 0 |
| **M5. Product surface** — user-facing settings controls | ≤ 8 |
| **M6. Runtime dependencies** — third-party libraries linked | 0 |
| **M7. Accuracy** — subjective: no worse than the platform’s built-in dictation on the user’s daily vocabulary, and better on their custom terms | — |

---

## 4. Users & Scenarios

**Primary user:** a single power user on an Apple-Silicon MacBook running current macOS, who dictates
long-form text daily into editors, browsers, chat apps, and terminals, and values speed and privacy.

**Secondary users:** a handful of friends the primary user may share a signed build or source code with. This is why
device-specific behavior (e.g. display geometry) **MUST** be derived dynamically rather than hardcoded
(§8.8), and why the build **MUST** be distributable (§15).

**Key scenarios:**

1. **Quick dictation** — a sentence into a chat box. Press, speak ~5 s, press, text appears.
2. **Long-form dictation** — several minutes of continuous speech into an editor. Must remain responsive,
   must not stall on stop, must not lose text. Sentences must flow naturally.
3. **Missed-paste recovery** — the user dictates, but focus changed (a dialog stole it) and the text landed
   nowhere useful. The user opens the menu-bar item and re-copies the last result into the right place.
4. **Terminal dictation** — dictating a command into a terminal emulator, including ones with restrictive
   input handling.
5. **External display / clamshell** — the laptop drives an external monitor (lid open or closed); the 
   laptop has an external microphone or bluetooth headset connected; the indicator and microphone behavior must remain correct.
6. **First run on a friend’s Mac** — permissions and the on-device model are set up with clear guidance,
   offline-friendly where possible. There is a reset button to fix setup issues.

---

## 5. Design Principles

1. **Performance and accuracy first, everywhere.** When a choice trades one against surface or elegance,
   performance/accuracy win. Complexity is welcome *only* where it buys speed or accuracy; it is refused
   when it merely adds a feature or a knob.
2. **Invisible until invoked.** Orator has no window in normal use. The indicator *is* the interface.
3. **The target field is sacred; the preview is disposable.** Provisional recognition and a waveform / vu indicator may be shown for
   confidence, but the user’s actual text is written exactly once, when finalized.
4. **Never surprise, never get stuck.** Every state is escapable; every failure is legible; no operation
   leaves a phantom indicator or a lost recording.
5. **Native to the letter.** Follow the platform Human Interface Guidelines, use system controls and system
   affordances, and borrow the system’s own visual language (e.g. the recording-active accent) rather than
   inventing one.
6. **Boring to maintain.** Prefer the oldest, most stable API that does the job. One code path beats a
   configurable system. A single developer must be able to hold the whole app in their head.

---

## 6. Platform, Frameworks & Permissions

### 6.1 Platform

- **Deployment target: macOS 26.0, Apple Silicon.** This floor is *forced* by the engine choice: the
  on-device streaming Speech analyzer/transcriber used here is a macOS-26-era, Swift-only API. There is no
  supported fallback engine, and one **MUST NOT** be added to widen compatibility (ORA-PLAT-002).
- **Language/toolchain:** Current Swift, current Xcode, strict concurrency enabled.

### 6.2 Frameworks (all first-party)

| Concern | Framework / API |
|---|---|
| Speech recognition | **Speech** framework — streaming analyzer + transcriber, plus the asset/model inventory API |
| Audio capture | **AVFoundation** — `AVCaptureSession` + `AVCaptureAudioDataOutput`, `AVAudioConverter` |
| App shell / menu bar / panels | **AppKit** — `NSApplication`, `NSStatusItem`, `NSMenu`, `NSPanel`, `NSHostingView` |
| Indicator content rendering | **SwiftUI** hosted inside AppKit (`NSHostingView`) for the waveform/preview |
| Global hotkey | **Carbon** `RegisterEventHotKey` (primary); **CoreGraphics** event tap (scoped, only for Escape capture while recording) |
| Text insertion & focus | **ApplicationServices / Accessibility** (`AXUIElement`) and **CoreGraphics** (`CGEvent`) |
| Display geometry | **AppKit** `NSScreen` (`safeAreaInsets`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`) |
| Microphone selection | **AVFoundation** `AVCaptureDevice` (follow the system default, or pin the built-in only; the built-in is matched by CoreAudio transport type) |
| Launch at login | **ServiceManagement** (`SMAppService`) |

**No third-party runtime dependencies (ORA-PLAT-003, MUST).** The on-device model is provided and stored
by the platform; Orator ships no model weights and links no ML runtime.

### 6.3 App type & signing

- **Menu-bar agent:** `LSUIElement = true` (no Dock icon, no default window). (ORA-PLAT-004, MUST)
- **Not sandboxed.** Controlling other applications via the Accessibility API and posting global events is
  incompatible with the App Sandbox. Orator **MUST** run without the sandbox, with the **Hardened Runtime**
  enabled. (ORA-PLAT-005)
- **Distribution:** **Developer ID signed and notarized.** This is required both for a friend’s Gatekeeper
  to admit the app and, crucially, for stable TCC (privacy) grants during development — permission grants are
  keyed to the code signature, and unstable signing corrupts the grant state. (ORA-PLAT-006, MUST; see §15)

### 6.4 Permissions (TCC)

| Permission | Why | Mechanism |
|---|---|---|
| **Microphone** | capture speech | `NSMicrophoneUsageDescription`; `AVCaptureDevice.requestAccess(for: .audio)` |
| **Speech Recognition** | governs on-device model assets, not a TCC prompt | The streaming `SpeechAnalyzer`/`SpeechTranscriber` path exposes **no** `requestAuthorization` call; model access is gated by `AssetInventory`, not by speech-recognition TCC; no `NSSpeechRecognitionUsageDescription` is declared, and the hot path MUST NOT block on a speech-recognition authorization request. |
| **Accessibility** | read focused element, insert text, post ⌘V, register the scoped Escape tap | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` |
| **Input Monitoring** | *only if* the scoped Escape capture requires a listen tap on some configurations | `IOHIDCheckAccess` / request as needed |

Requirements:

- ORA-PERM-001 (MUST): On first run, Orator MUST detect which permissions are missing and deep-link the user
  to the exact Privacy & Security pane for each, with plain-language guidance.
- ORA-PERM-002 (MUST): Orator MUST re-check permission state when the app regains focus, so a grant made in
  System Settings takes effect without a manual restart, and a *stale* grant (present in the list but not
  effective, e.g. after reinstall) is detected and surfaced with a remediation hint.
- ORA-PERM-003 (MUST): With a **record-blocking** permission missing (Microphone) or the model
  unavailable, the menu-bar icon MUST show a “not ready” warning state and the hotkey path MUST fail
  safe (no crash, a legible reason). An **Accessibility-only** gap MUST NOT force the not-ready icon:
  recording still works with insertion routed to the recovery buffer (E2). It MUST instead be surfaced in
  the menu banner and tooltip with a remediation hint. The icon answers “can I dictate right now?”, and
  with only Accessibility missing the answer is yes.

---

## 7. Architecture

### 7.1 Component overview

```
                         ┌─────────────────────────────┐
   global hotkey ───────▶│      SessionCoordinator      │  (@MainActor, explicit state machine)
   Escape (scoped tap) ─▶│  idle→recording→finalizing→  │
                         │        inserting→idle        │
                         └──┬───────────┬──────────┬─────┘
                            │           │          │
              start/stop    │           │ results  │ final text
                            ▼           │          ▼
                   ┌────────────────┐   │   ┌──────────────────┐
                   │ AudioCapture   │   │   │ TextInserter     │
                   │ AVCaptureSess. │──▶│   │ paste; AX only   │
                   │ →converter     │ AsyncStream│ locates/checks │
                   └────────────────┘  of │   └──────────────────┘
                            ▲       AnalyzerInput │
                            │              ▼      │
                   capture  │       ┌──────────────────┐   ┌────────────────┐
                   runtime- │       │ SpeechEngine     │   │ RecoveryBuffer │
                   error obs│       │ analyzer+transcr.│──▶│ mem-only, 5-min │
                            │       │ resident/warm    │   └────────────────┘
                            │       └──────────────────┘            │
                   ┌────────┴─────────┐                             ▼
                   │ IndicatorController │◀───────────── state, level, preview
                   │ menu-bar item +     │
                   │ notch/pill panel    │
                   └─────────────────────┘
```

### 7.2 State machine

The **SessionCoordinator** is the single owner of dictation lifecycle. All lifecycle events
(hotkey press, Escape, engine finalization, device change) are funneled through it and processed one at a
time. States:

| State | Meaning | Valid transitions |
|---|---|---|
| `idle` | ready, warm, not recording | → `recording` (on hotkey, if ready) |
| `recording` | capturing + streaming to engine, accumulating confirmed text | → `finalizing` (hotkey/max-duration), → `idle` (Escape/cancel), → `recording` (survivable device change) |
| `finalizing` | flushing the engine’s volatile tail into confirmed text, bounded by a timeout | → `inserting` (got final or hit cap) |
| `inserting` | placing text into the target field | → `idle` |

Invariants (all MUST):

- ORA-SM-001: The coordinator MUST run on the main actor and process one event at a time; concurrent audio
  and engine work happens off-main and delivers results *to* the coordinator, never mutating its state directly.
- ORA-SM-002: **Confirmed text lives in the coordinator, outside the audio and engine object lifecycles.**
  It MUST survive any audio-graph or engine reconfiguration and MUST be recoverable even if insertion never
  happens.
- ORA-SM-003: A new `recording` MUST NOT begin while a prior session is `finalizing` or `inserting`
  (busy guard); such a hotkey press is ignored.
- ORA-SM-004: The coordinator MUST enter `recording` only after audio capture has actually started; if
  capture fails to start, it MUST return to `idle` with a legible error and MUST NOT show a recording indicator.

### 7.3 Concurrency model

- ORA-CC-001 (SHOULD): Use a single `@MainActor` coordinator with an explicit `enum` state rather than an
  `actor`. Reentrancy and ordering are easier to reason about on the main actor for a UI-driven lifecycle,
  and it avoids actor-hop latency on the hot path.
- ORA-CC-002 (MUST): The `AVCaptureAudioDataOutput` sample-buffer delegate runs on a dedicated capture queue. It MUST do only:
  convert the buffer to the engine’s required format and `yield` it into an `AsyncStream`. It MUST NOT hop to
  the main actor, allocate heavily, or block.
- ORA-CC-003 (MUST): Exactly one long-lived `Task` consumes the engine’s result stream and forwards
  confirmed/volatile updates to the coordinator.

---

## 8. Functional Requirements

### 8.1 Activation & Hotkey

- ORA-ACT-001 (MUST): Orator MUST support a single, user-configurable global hotkey operating in
  **toggle mode**: first press starts a dictation, second press stops it. There is no push-to-talk mode.
  *Rationale: the primary use is long, hands-free dictation; holding a key for minutes is untenable.*
- ORA-ACT-002 (SHOULD): The hotkey SHOULD be registered via the platform’s Carbon hotkey registration
  (`RegisterEventHotKey`), which requires no privacy permission and is robust against the secure-input and
  event-tap failure modes described in §13. *Rationale: reliability of the single most-used control.*
- ORA-ACT-003 (MUST): **Escape cancels** an in-progress dictation, discarding all audio and text without
  inserting anything. (See §8.2; the capture mechanism is a scoped CGEvent tap, §11.4.)
- ORA-ACT-004 (MUST): Rapid repeated presses MUST be debounced (a press within ~30 ms of the prior press is
  ignored) to prevent double-toggle from key chatter.
- ORA-ACT-005 (SHOULD NOT): Orator SHOULD NOT bind the fn/Globe key by default, as it collides with the
  system dictation binding and requires a lower-level tap.
- ORA-ACT-006 (MUST): If the hotkey cannot function (missing permission, or global secure keyboard entry is
  active system-wide), Orator MUST reflect this in the menu-bar icon and menu so the cause is discoverable.

### 8.2 Session lifecycle — see state machine §7.2

- ORA-SM-010 (MUST): A dictation MUST have a **generous maximum duration** (default ~30 minutes) after which
  it auto-stops as if the user pressed stop, to prevent an unattended forgotten session recording indefinitely.
- ORA-SM-011 (MUST NOT): Orator MUST NOT implement silence-based auto-stop in v1. In toggle mode the user
  controls start/stop; silence detection adds complexity and failure modes for no required benefit.
- ORA-SM-012 (MUST): On cancel (Escape), the coordinator MUST discard audio, confirmed text, and volatile
  text, tear down capture, and return to `idle`, with no insertion and no recovery-buffer entry.

### 8.3 Audio Capture

- ORA-CAP-001 (MUST): Capture MUST use `AVCaptureSession` + `AVCaptureAudioDataOutput` (not `AVAudioEngine`)
  and convert to the recognizer's required format with a single `AVAudioConverter`. On macOS 26 / Swift 6,
  `AVAudioEngine.prepare()`/`.start()` corrupt the Swift main-actor executor identity process-wide, after which
  every `MainActor.assumeIsolated` (Orator's own and SwiftUI's internal isolation assertions) traps
  (`swift_task_isCurrentExecutor` → EXC_BAD_ACCESS); `AVCaptureSession` performs the same capture without that
  side effect. Fed one capture buffer at a time, the `AVAudioConverter` produces valid downsampled output and
  *then* reports `.inputRanDry` rather than `.haveData`; the sink MUST accept any non-`.error` status that
  produced frames — gating on `.haveData` alone silently drops every buffer (no waveform, transcript, or
  insertion).
- ORA-CAP-002 (SHOULD): By **default, follow the system default input device** (the mic the user has already
  chosen), with an optional setting to pin the built-in microphone instead. *Rationale: following the system
  default respects the mic the user picked in System Settings and keeps working across an external-display/
  clamshell setup with no per-device configuration; the built-in pin lets a user avoid a low-bandwidth
  Bluetooth hands-free (HFP) path, which materially degrades recognition.* The built-in mic MUST be identified
  by its CoreAudio **transport type** (`kAudioDeviceTransportTypeBuiltIn`) matched to an `AVCaptureDevice` by
  UID, not by a name substring — on Apple Silicon the built-in is named for the model ("MacBook Air
  Microphone"), so a name match can fall through to a flaky Continuity/iPhone mic that disconnects mid-session.
- ORA-CAP-003 (MUST): Orator MUST handle audio configuration changes mid-session (a headset connecting):
  `AVCaptureSession` recovers from most device changes itself; the sample-buffer delegate rebuilds the
  `AVAudioConverter` when the input format changes, and confirmed text MUST survive (ORA-SM-002). A session
  runtime error that truly stops capture is surfaced so the parked text is recoverable (ORA-REL-002).
- ORA-CAP-005 (SHOULD): Protect the leading phoneme of the first word from capture start-up clipping.
  Protection is provided by (a) the audio graph being prepared warm (ORA-CAP-006) so `start` is near-instant,
  and (b) the capture→analyzer path being an unbounded buffered `AsyncStream`, so no captured buffer is dropped
  between start and the analyzer consuming it. A warm pre-roll buffer is deliberately not used: it would keep
  the microphone hot outside a dictation (the OS mic-in-use indicator permanently lit) — an unacceptable
  privacy cost.
- ORA-CAP-006 (MUST): The audio graph MUST be **prepared while warm** (§8.11) so starting a dictation does not
  pay audio-graph setup latency (M1).

### 8.4 Speech Recognition

- ORA-ASR-001 (MUST): Transcription MUST run **entirely on-device** using the platform Speech analyzer +
  transcriber. No audio or text leaves the machine.
- ORA-ASR-002 (MUST): Orator MUST **stream** audio to the recognizer continuously during `recording` and
  accumulate **confirmed** results as they arrive. It MUST NOT wait until stop to transcribe the whole buffer.
  *Rationale: for a multi-minute dictation, batch transcription at stop would stall for seconds; streaming makes
  stop a tail-flush (M2).*
- ORA-ASR-003 (MUST): On stop, Orator MUST finalize the recognizer (flush the volatile tail into confirmed
  text) under a **bounded timeout** (default ~2500 ms, M3). If the timeout elapses, Orator MUST insert the
  confirmed text obtained so far **together with the unfinalized volatile tail**, rather than block the user.
  A slow finalize is not grounds for withholding text from a target that is still focused: insertion
  re-verifies the frontmost app (ORA-INS-002), so a tail that genuinely cannot be placed still routes to the
  recovery buffer per ORA-REC-004 — but that decision belongs to the insertion step, not to the timeout.
- ORA-ASR-004 (MUST): Provisional/volatile results MAY be surfaced only in the indicator preview (§8.8) and
  MUST NOT be written to the target field.
- ORA-ASR-005 (MUST): The recognizer instance and its model MUST be kept **resident/warm** for the app’s
  lifetime (no idle auto-unload) so no dictation pays a model load (M1). *Note: model residency is achieved by
  keeping a prepared analyzer/transcriber instance alive, not merely by reserving the asset.*
- ORA-ASR-006 (MUST): The on-device model asset MUST be acquired via the platform asset-inventory flow:
  `AssetInventory.status(forModules:)` to probe, then `AssetInventory.assetInstallationRequest(supporting:)` →
  `downloadAndInstall()` with progress read from `AssetInstallationRequest.progress`. First run MUST present
  explicit download progress and a retry affordance, and MUST treat download failure as a first-class
  onboarding state, not a fatal error.
- ORA-ASR-007 (SHOULD): Native punctuation from the recognizer SHOULD be preserved as-is; Orator SHOULD NOT
  apply a spoken-punctuation substitution layer in v1. As the one sanctioned default edit (a narrow exception
  to ORA-ACC-002), Orator MAY trim a run of stray leading sentence-delimiter punctuation at the very start of a
  finalized utterance (the recognizer renders an opening pause/breath as "..", ",…", "…") and capitalize the
  first word; internal punctuation and casing are left untouched.
- ORA-ASR-008 (MUST): The active locale is a setting. The Language picker is populated **dynamically** from
  `SpeechTranscriber.supportedLocales` (every locale the on-device transcriber supports — not a hard-coded
  list). Selecting a locale whose model isn't installed triggers the OS model install
  (`AssetInstallationRequest.downloadAndInstall`) after an explicit confirmation, with inline progress; the
  selection is committed only on success and reverts on cancel/failure (a failed download never strands a
  broken selection). Locale names are shown localized to the user's system language.

### 8.5 Vocabulary & Correction

- ORA-VOC-001 (MUST): Orator MUST let the user maintain a **custom vocabulary** (names, jargon, product
  terms) that biases recognition toward those terms.
- ORA-VOC-002 (MUST): The vocabulary MUST be supplied to the recognizer through the Speech framework’s
  contextual mechanism — per-request contextual biasing via `AnalysisContext.contextualStrings[.general]`,
  applied to the analyzer's context at session start. **Only `DictationTranscriber` honours contextual
  strings**; `SpeechTranscriber` accepts the context without error and ignores it, so a session with a
  non-empty vocabulary MUST run on `DictationTranscriber` (sessions with no vocabulary keep the default
  `SpeechTranscriber`). Contextual strings are capped at 100 terms — an oversized array can drop the whole
  set rather than the excess. Custom *pronunciations* via `SFCustomLanguageModelData` are deferred (§17) and
  not needed for term biasing.
- ORA-VOC-003 (SHOULD, deferred): A conservative post-recognition correction pass MAY repair systematic
  mis-splits of known custom terms (e.g. a multi-token rendering collapsing into a single vocabulary term).
  If built, it **MUST** operate only against the user’s explicit vocabulary, use a precision-first threshold,
  preserve original casing and punctuation, and **never** alter text that does not closely match a known term.
  *Deferred: a correction pass that fires too eagerly harms accuracy, which is priority #1.*
- ORA-VOC-004 (MUST NOT): Orator MUST NOT strip disfluencies/filler words by default. Verbatim output is the
  accurate output; removing words risks removing intended ones.

### 8.6 Text Insertion

- ORA-INS-001 (MUST): On finalize, Orator MUST insert the confirmed text **once**, as a single unit, into the
  target field. It MUST NOT stream partial text into the field.
- ORA-INS-002 (MUST): Orator MUST capture the **target application’s process identity at record-start**, and at
  insert-time MUST re-fetch the focused element and confirm the frontmost application still matches before
  inserting; if focus has moved to a different app, it MUST route the result to the recovery buffer (§8.7)
  rather than insert into the wrong place.
- ORA-INS-003 (MUST): Orator MUST insert via a **single** strategy — **paste** — placing text on the
  pasteboard (with the ORA-INS-005 discipline) and synthesizing the paste keystroke. This path is universally
  compatible (browser, web-view/Chromium-based apps, terminals) and participates in the host app's undo.
  Accessibility is used **only** to locate the focused element, detect secure fields (ORA-INS-007), confirm the
  frontmost app (ORA-INS-002), and best-effort *verify* the paste landed (by observing the focused value grow)
  — **not** to write text. Rationale: one insertion code path is the "boring to maintain" choice (Principle 6).
- ORA-INS-004 (SHOULD): The paste keystroke SHOULD be posted with the Command modifier using the key code that
  types "v" in the **current keyboard layout** (resolved from the active Unicode keyboard layout), so paste
  works on non-QWERTY layouts (Dvorak, AZERTY, …); it MUST fall back to the ANSI-V physical key code when the
  layout can't be read, so the worst case equals a fixed key code.
- ORA-INS-005 (MUST): For the paste path, Orator MUST:
  - Save the **entire** existing pasteboard contents (all representations, not just plain string) and record
    the pasteboard `changeCount`.
  - Mark its own pasteboard write as **transient/concealed** (using the concealed-content pasteboard type) so
    clipboard-manager utilities do not persist the dictated text to disk.
  - Restore the original contents on a background task **after** the paste is verified, *unless* the
    `changeCount` has advanced (the user copied something meanwhile), in which case it MUST NOT clobber the
    newer clipboard.
  - Fire the completion cue immediately after the paste verifies; clipboard restore MUST NOT block it.
- ORA-INS-006 (SHOULD): For host applications known to require synthetic paste and/or a longer settle delay
  (e.g. certain terminal emulators), Orator SHOULD apply the necessary per-application adjustment. This is a
  minimal built-in lookup, not a user-facing configuration system.
- ORA-INS-007 (MUST NOT): Orator MUST NOT insert into a secure text field (password fields refuse programmatic
  input); it MUST detect this case and route the result to the recovery buffer with a legible reason.
- ORA-INS-008 (SHOULD): When the caret sits immediately after a non-whitespace character, Orator SHOULD prepend
  a single separating space to the inserted text so back-to-back dictations into the same field do not run
  together. This is best-effort: it reads the field value and caret offset via Accessibility and does nothing
  when either is unavailable.

### 8.7 Recovery Buffer

- ORA-REC-001 (MUST): Orator MUST retain the most recent dictation results in an **in-memory** list, presented
  as items in the menu-bar dropdown, so the user can recover text if insertion missed its intended field.
- ORA-REC-002 (MUST): Selecting an item MUST copy its text to the clipboard (marked concealed per ORA-INS-005)
  so the user can paste it where intended.
- ORA-REC-003 (MUST): Entries MUST expire on a **hard time-to-live of 5 minutes** and be removed by a timer
  that runs independently of user activity (i.e. entries expire even if the menu is never opened). On removal,
  the backing string MUST be released/overwritten.
- ORA-REC-004 (MUST): Results that could not be inserted (focus changed, secure field, finalization timeout)
  MUST be placed into the recovery buffer so no spoken text is ever lost (M4).
- ORA-REC-005 (MUST NOT): The recovery buffer MUST NOT be written to disk by Orator. *(Honest scope: the OS may
  page memory to swap; Orator does not itself persist the data. See §13 R10.)*
- ORA-REC-006 (SHOULD): The buffer SHOULD hold a small bounded number of entries (e.g. ≤ 10) regardless of the
  TTL, to keep the menu compact.

### 8.8 Indicators

**Menu-bar item (baseline, always present):**

- ORA-IND-001 (MUST): A `NSStatusItem` MUST always be present and MUST encode state in its icon. The menu-bar
  icon is deliberately calm — the notch/pill panel carries the in-progress detail: **ready** = a white
  `waveform`; **recording** = an orange `waveform` (the mic-in-use accent, §10.2); **working**
  (finalizing/inserting) = the same white `waveform` (the panel shows the processing spinner); **not-ready**
  (permission/model issue) = a white `exclamationmark.triangle`. The recording⇄white transition crossfades.
- ORA-IND-002 (MUST): Its menu MUST expose: the recovery-buffer entries, a settings entry, permission/asset
  status when relevant, and quit.

**Notch / pill panel (rich indicator):**

- ORA-IND-010 (MUST): While recording, Orator MUST present a floating indicator showing a **live audio
  waveform**, **elapsed time**, and a **live-preview transcript** (volatile words), whose sole purpose is to
  give confidence that recording is working. This preview is disposable and never feeds the target field
  (Principle 3). The waveform occupies the **leading orb** slot; on stop, that orb **morphs from the waveform
  into a white processing spinner** (same slot, colour + shape transition) for the finalizing/inserting states.
- ORA-IND-011 (MUST): On a display with a camera notch, the indicator MUST render as a black panel that is
  flush to the top edge and **grows downward out of the notch as a rounded "chin," placing all content BELOW
  the opaque notch band** so the camera housing never occludes it. It MUST read as one continuous form
  extending the notch (a seamless "the notch grew"), **not** a separate element floating below with a gap. Its
  top corners MUST be **concave inverse fillets tangent to the menu-bar line** — the panel's sides curve
  outward and up back into the bar (the `\__/` the notch itself makes) — using radii consistent with the
  hardware notch (≈ 4 pt top / 8 pt bottom, §11.3). The top **notch band** (height = the physical notch height)
  is reserved and content-free; the waveform/preview/timer live in the chin below it.
- ORA-IND-012 (MUST): **The panel geometry MUST be fixed at record-start and MUST NOT resize when transcript
  text arrives.** The preview is a fixed-size single-line window onto the *tail* of the confirmed/volatile text;
  older words scroll off, the box never grows. *(Implementation: size the panel at the AppKit layer and disable
  content-driven sizing on the hosted SwiftUI view; see §11.)*
- ORA-IND-013 (MUST): Notch geometry MUST be derived **dynamically**: notch **height** = `safeAreaInsets.top`;
  notch **width** = `screen.frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`. Hardcoded
  per-model constants MAY exist only as a clearly-labelled last-resort fallback — real measured values are
  **14-inch 185×32 pt** and **16-inch 220×38 pt**, corner radii ≈ 4 pt (top) / 8 pt (bottom). Dynamic
  detection is preferred precisely so the app works on other machines.
- ORA-IND-014 (MUST): On displays without a notch, the indicator MUST render as a rounded **pill** centered
  under the menu bar with identical content. Orator MUST NOT fake a notch where none exists.
- ORA-IND-015 (MUST): The indicator MUST appear on the screen containing the frontmost app’s key window; the
  notch treatment is used only when that screen is the built-in notched display, otherwise the pill is used.
  Geometry MUST be recomputed on screen-parameter changes (display connect/disconnect, lid open/close).
- ORA-IND-016 (MUST): The indicator panel MUST be a **non-activating** panel that **never becomes key**,
  joins all Spaces, floats over full-screen apps, and sits above the menu-bar level. It MUST NOT steal focus
  from the target field (a panel that takes key focus would break insertion).
- ORA-IND-017 (MUST): The indicator MUST honor Reduce Motion (no expansion animation; appear at final size)
  and Reduce Transparency.
- ORA-IND-018 (SHOULD): The downward-reveal animation is polish and SHOULD be implemented last; the
  fixed-size static panel is the functional requirement.

### 8.9 Audio Feedback

- ORA-FBK-001 (SHOULD): Orator SHOULD play a subtle **start** cue and **stop** cue. The start cue plays
  concurrently with capture start rather than gating it: meeting the start-latency budget (M1, a MUST) takes
  precedence over keeping the cue out of the audio, and a brief overlap of a subtle cue is acceptable.
- ORA-FBK-002 (MAY): Orator MAY duck other system audio while recording to reduce speaker bleed into the mic.
  This MUST be off by default (it is intrusive) and MUST be a setting if offered.
- ORA-FBK-003 (SHOULD): Cues SHOULD respect the system output device and a user volume setting, and SHOULD be
  suppressible.

### 8.10 Settings

- ORA-CFG-001 (MUST): Settings MUST be a single small pane exposing at most: hotkey, language/locale,
  microphone choice (follow-default vs. built-in only), custom vocabulary list, launch-at-login, and sound
  on/off. (≤ 8 controls, M5.)
- ORA-CFG-002 (MUST): Settings MUST persist via `UserDefaults`, each key with an explicit default read
  lazily at the call site (a fresh install and a missing key are indistinguishable and both yield the
  default). No schema-version stamp or migration scaffold is carried until a key's meaning actually
  changes — introduce one, guarded by the old value, at that point.
- ORA-CFG-003 (MUST): Launch-at-login MUST use `SMAppService`.
- ORA-CFG-004 (MUST NOT): There MUST be no per-app profiles, no workflow editor, no prompt/LLM configuration,
  no model picker, no plugin catalog.

### 8.11 Onboarding, Warmth & Lifecycle

- ORA-LIF-001 (MUST): At launch, Orator MUST bring itself **warm**: prepare the audio graph, instantiate and
  keep resident the recognizer, and (if the model asset is present) be ready to dictate with no further setup.
- ORA-LIF-002 (MUST): First run MUST guide the user through permissions (§6.4) and model acquisition (§8.4)
  with clear, offline-friendly states.
- ORA-LIF-003 (SHOULD): Orator SHOULD add negligible idle resource cost; the resident model’s memory is the
  dominant cost and is an accepted trade for zero cold-load latency.

---

## 9. Non-Functional Requirements

### 9.1 Performance

- ORA-PERF-001 (MUST): Meet M1 (start ≤ 50 ms) and M2 (stop→inserted ≤ 500 ms typical) on the target hardware.
- ORA-PERF-002 (MUST): Bound finalization by M3 (≤ 2500 ms) with graceful degradation (ORA-ASR-003).
- ORA-PERF-003 (MUST): Nothing on the hot path may perform a cold model load, a WAV/file encode, a network
  call, or a blocking main-thread operation.
- ORA-PERF-004 (SHOULD): Instrument per-stage latency (start, first-confirmed, stop→final, final→inserted)
  behind an off-by-default local debug switch (§9.8) to enable tuning without guesswork.

### 9.2 Accuracy

- ORA-ACC-001 (MUST): Prefer input-quality and biasing measures that raise accuracy (a good input device,
  custom vocabulary) over cosmetic post-processing that risks it.
- ORA-ACC-002 (MUST): Any transformation of recognizer output MUST be conservative and reversible in intent —
  no default lossy edits, except the single narrow leading-artifact trim sanctioned in ORA-ASR-007
  (ORA-VOC-004, ORA-ASR-007).

### 9.3 Privacy

- ORA-PRIV-001 (MUST): No network egress for any core function. Orator MUST function fully offline once the
  model asset is present.
- ORA-PRIV-002 (MUST): No telemetry, analytics, crash reporting, or remote configuration.
- ORA-PRIV-003 (MUST): Dictated text is not persisted by Orator (ORA-REC-005); clipboard writes are concealed
  (ORA-INS-005).

### 9.4 Reliability & mid-session survival

- ORA-REL-001 (MUST): No session may leave a phantom indicator or a stuck state (ORA-SM-*).
- ORA-REL-002 (MUST): A device change or engine stall during a long dictation MUST NOT lose already-confirmed
  text (ORA-SM-002, ORA-CAP-003). Losing minutes of confirmed speech is the worst possible failure and is
  explicitly designed out.

### 9.5 Security

- ORA-SEC-001 (MUST): Respect secure input: do not attempt to insert into secure fields; detect global secure
  keyboard entry and reflect degraded hotkey capability (ORA-ACT-006).
- ORA-SEC-002 (MUST): Treat dictated content as sensitive: conceal clipboard writes, keep the recovery buffer
  in memory, and expire it aggressively.

### 9.6 Accessibility (of Orator’s own UI)

- ORA-A11Y-001 (SHOULD): Orator’s menu, settings, and indicator SHOULD be VoiceOver-legible and keyboard-navigable
  where they are interactive, and SHOULD respect Reduce Motion/Transparency and Increase Contrast.

### 9.7 Resource use

- ORA-RES-001 (SHOULD): Idle CPU ≈ 0; memory dominated by the resident model; no background polling loops.

### 9.8 Maintainability

- ORA-MNT-001 (SHOULD): Keep the product surface within M5/M6 budgets; new user-facing surface requires
  justification against Principle 1.
- ORA-MNT-002 (MAY): Provide an **off-by-default** local debug log (transcripts + timings) enabled by an
  explicit developer switch during tuning; it MUST be clearly not part of normal operation and MUST NOT ship
  enabled. *This is the only sanctioned way to get an accuracy/latency feedback loop given the no-telemetry posture.*

---

## 10. Interaction & Visual Design

### 10.1 Core interaction flow

The state machine is §7.2; the user-facing sequence:

1. **Start:** the menu-bar icon switches to its recording state; the notch/pill indicator appears at fixed
   size; a subtle start cue plays; the waveform animates and the live preview begins streaming words.
2. **During:** the user speaks freely; the waveform and preview reassure that capture is live; elapsed time
   counts up. Nothing appears in the target field.
3. **Stop:** the indicator shows a brief finalizing state; within the latency budget the text is inserted
   into the target field in one shot; a stop cue plays; the indicator dismisses.
4. **Cancel:** Escape discards everything; the indicator dismisses with no insertion.
5. **Recover:** if the text landed nowhere useful, the user opens the menu-bar item and selects the last
   result to copy it, then pastes it into the intended field.

### 10.2 Indicator visual language

- Use the **system’s microphone-in-use indicator color** (orange) as the indicator’s signal color, rather than
  inventing a palette. (Red is avoided: a red mic reads as the videoconferencing *muted* idiom.)
- The notch panel is a single black region that extends the opaque notch **downward** into a rounded chin;
  its content — a **leading orb** (narrow waveform), a single-line text tail, and elapsed time — sits in the
  chin **below** the notch band, and the orb **morphs into a white spinner** on stop (ORA-IND-010/011).
- The pill (no-notch case) is the same content in a centered rounded capsule beneath the menu bar.
- Motion: a single deliberate **downward** reveal — the chin grows out of the notch — ≤ ~250 ms, ease-out;
  suppressed entirely under Reduce Motion.

### 10.3 Copy & tone

- Plain, verb-first, non-technical. States name what is happening (“Listening…”, “Placing text…”), errors
  name the fix (“Grant Accessibility to insert text — Open Settings”). No jargon, no apologies.

### 10.4 HIG conformance

- Menu-bar agent conventions, standard `NSMenu`, standard settings window, SF Symbols for iconography,
  respect for appearance (light/dark), Reduce Motion/Transparency, and Increase Contrast.

---

## 11. Detailed Design Notes

> The following illustrate intended API usage. They reference only first-party Apple APIs and are
> non-normative; the normative requirements are in §8–§9.

### 11.1 App shell

- `NSApplication` with an `NSApplicationDelegate` main entry (AppKit lifecycle), `LSUIElement` true,
  `activationPolicy = .accessory`. The SwiftUI `App`/`MenuBarExtra` lifecycle is avoided because global
  hotkeys, non-activating panels, and Accessibility control are AppKit-native and fight the SwiftUI scene model.
- Menu bar: `NSStatusItem` with an `NSMenu`. Recovery entries are `NSMenuItem`s rebuilt on menu-open and on
  buffer changes.

### 11.2 Indicator panel

- A borderless `NSPanel`, `styleMask` includes `.nonactivatingPanel`; `level` above `.mainMenu`;
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`; `hidesOnDeactivate = false`;
  never becomes key. Content is a SwiftUI view in an `NSHostingView`.
- **Fixed size enforcement:** set the hosting view’s `sizingOptions = []` and set the panel’s frame explicitly
  at record-start. This prevents SwiftUI content from resizing the window when the preview text changes
  (satisfies ORA-IND-012). The preview `Text` is single-line with truncation showing the tail.
- Waveform: SwiftUI `TimelineView` + `Canvas`, driven by audio level values pushed from the capture layer;
  no Metal/`CADisplayLink` needed at this size.

### 11.3 Notch geometry

- Notched if `screen.safeAreaInsets.top > 0`. Notch **height** = `safeAreaInsets.top`; notch **width** =
  `screen.frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`; centre = the screen's
  horizontal centre. Recompute on `NSApplication.didChangeScreenParametersNotification`.
- **The physical notch is opaque** (camera housing) — no content is placed in it. The panel is flush to the
  top; its top `notchBand` (= the notch height) is reserved and empty, and the content row (leading orb +
  preview tail + timer) is laid out in the rounded **chin** below (ORA-IND-011). The chin is revealed by a
  downward reveal at record-start (grows out of the notch); suppressed under Reduce Motion.
- The silhouette is a `Shape` with **concave inverse top corners** (tangent to the menu-bar line, so the sides
  curve outward and up into the bar) and a rounded bottom chin — radii and measured dimensions per
  ORA-IND-013.
- Waveform: SwiftUI `Canvas` driven by pushed audio levels. The leading orb crossfades the waveform into a
  white `SpinnerRing` (a trimmed, rotating `Circle`) for the finalizing/inserting states.

### 11.4 Hotkey & Escape

- Toggle: `RegisterEventHotKey` (Carbon) — no TCC permission, robust.
- Escape capture (only while recording): a scoped `CGEvent` tap created on record-start and torn down on stop,
  swallowing exactly Escape. Handle `tapDisabledByTimeout` by re-enabling. If the tap cannot be created (denied,
  or global secure input active), degrade: Escape falls back to clicking the indicator/menu to cancel.

### 11.5 Speech pipeline

- Keep one prepared analyzer + transcriber alive for the app lifetime. Feed `AnalyzerInput` buffers via an
  `AsyncStream` produced by the audio tap. Consume the transcriber’s result stream in one long-lived `Task`,
  routing confirmed results to the coordinator’s accumulator and volatile results to the indicator preview.
- On stop: request finalization and race it against a ~2.5 s timeout; whichever resolves first drives insertion.

### 11.6 Insertion

- Focus/target: read the system-wide focused `AXUIElement`; record the owning PID at record-start; re-read at
  insert-time and confirm the frontmost PID matches.
- Insertion (paste only): snapshot all pasteboard items + `changeCount`; write text with the concealed type;
  synthesize Cmd+V via the layout-aware paste key code; verify by observing the focused value grow; restore original
  items on a background task unless `changeCount` advanced. Accessibility only locates/verifies — it never
  writes text.

### 11.7 Info.plist / entitlements (key items)

- `LSUIElement = true`; `NSMicrophoneUsageDescription` (the streaming analyzer path needs no
  speech-recognition prompt, so no `NSSpeechRecognitionUsageDescription` is declared); Hardened Runtime
  with the audio-input entitlement; **no** App Sandbox entitlement.

---

## 12. Error Handling & Edge Cases

| # | Situation | Required behavior |
|---|---|---|
| E1 | Microphone permission denied | Not-ready icon; hotkey no-ops with a deep-link to grant; no crash. (ORA-PERM-003) |
| E2 | Accessibility not granted | Recording works, insertion routes to recovery buffer; prompt to grant. |
| E3 | Model asset missing/first run | Guided download with progress + retry; dictation blocked until present. (ORA-ASR-006) |
| E4 | Model download fails / offline | First-class onboarding error state, ret/re-try; never an assert. |
| E5 | No microphone / mic removed | Fail to start cleanly, return to idle, legible reason. (ORA-SM-004) |
| E6 | Headset connects / mic unplugged mid-dictation | Fail over to the best remaining usable input and resume the SAME analyzer session (bounded retries, user told); confirmed text preserved. With no input left, end the dictation as a normal stop — finalize and insert — never dump straight to recovery. (ORA-CAP-003) |
| E7 | Finalization stalls past cap | Insert confirmed text **plus the unfinalized tail** into the still-focused target; recovery only if insertion itself can't place it; instrument the event. (ORA-ASR-003) |
| E8 | Focus changed before insert | Do not insert into the wrong app; route to recovery buffer. (ORA-INS-002) |
| E9 | Target is a secure field | Do not insert; route to recovery buffer with reason. (ORA-INS-007) |
| E10 | Global secure keyboard entry active | Reflect degraded hotkey/Escape; menu-driven fallback. (ORA-ACT-006) |
| E11 | External display focus / clamshell | Indicator on the active screen; pill when not the built-in; recompute on screen change. (ORA-IND-015) |
| E12 | No notch | Pill fallback; never fake a notch. (ORA-IND-014) |
| E13 | User copies during deferred restore | Do not clobber the newer clipboard (changeCount guard). (ORA-INS-005) |
| E14 | Very long dictation (approaching cap) | Auto-stop at ~30 min as a normal stop; text preserved. (ORA-SM-010) |
| E15 | Paste verify fails (focused value did not grow) | Route the result to the recovery buffer with a legible reason. (ORA-INS-003) |

---

## 13. Risk Register

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R2 | Asset inventory: reserve ≠ RAM residency; downloads can hang/fail; offline first-run has no model. | Medium | High | Residency via `AssetInventory.reserve(locale:)` **plus** a live prepared `SpeechAnalyzer`/`SpeechTranscriber` instance (reserve alone does not keep the model in RAM); first-run download via `AssetInstallationRequest.downloadAndInstall()` with `.progress` UI + retry; failure is an onboarding state, not fatal. |
| R3 | Stop→final latency is unbounded; a long/hiccupping session can stall at the product’s defining moment. | High | High | Accumulate confirmed text continuously; hard finalization cap (~2.5 s) then degrade; instrument from day one. |
| R4 | Audio config change (headset) invalidates tap/converter mid-session, risking loss. | High | High | Rebuild tap+converter, resume same session; confirmed text lives in coordinator, not the engine. |
| R5 | A CGEvent tap for the hotkey needs Accessibility, self-disables on timeout, and goes deaf under global secure input. | High | Medium | Use Carbon `RegisterEventHotKey` for the toggle; scope the tap to Escape-only while recording; reflect secure-input state. |
| R6 | Programmatic insertion is flaky: whole-value AX writes destroy undo/caret; web/Chromium fields reject or silently no-op; focus can move during finalization. | High | Medium | Paste-only insertion (host-app undo, universal compatibility); capture PID at start and re-verify the frontmost app at insert; verify the paste landed; route to the recovery buffer on mismatch/secure field. |
| R7 | Clipboard save/restore can destroy non-string clipboards, clobber a fresh copy, or be captured by clipboard managers. | Medium | Medium | Save all representations; changeCount guard; concealed type; layout-aware paste key code (resolved from the current keyboard layout). |
| R8 | Non-activating panel across Spaces/fullscreen/displays; a key-taking panel breaks paste; geometry changes with display/scale. | Medium | Medium | Never-key panel; correct collection behavior; recompute geometry on screen-parameter changes. |
| R9 | On-device LLM availability probe can misbehave if accessed too early. | Low (deferred) | Low | Do not link the LLM framework in v1 at all. |
| R10 | “Memory-only” recovery buffer can still page to swap; copy path re-exposes text. | Medium | Low–Med | Describe honestly as “not persisted by the app”; conceal the copy path; short TTL. |
| R11 | Permissions onboarding is certain friction; stale grants after reinstall are a known trap. | Certain | Medium | Detect + deep-link each pane; re-check on focus; stable Developer ID signing to keep TCC grants stable across rebuilds. |
| R12 | **`AVAudioEngine` corrupts the Swift main-actor executor** on macOS 26 / Swift 6, crashing the app when any SwiftUI view is shown after audio init (mechanism in ORA-CAP-001). | Certain (this toolchain) | Critical | Capture via `AVCaptureSession` + `AVCaptureAudioDataOutput` (does not corrupt the executor); convert `CMSampleBuffer` → `AVAudioPCMBuffer` → analyzer format (ORA-CAP-001). |

---

## 14. Verification & Acceptance

### 14.1 Approach

Each normative requirement is verified by one of: **inspection** (design/code review), **demonstration**
(scripted manual scenario), **measurement** (instrumented timing/resource), or **test** (automated unit/integration
where a seam allows).

### 14.2 Key acceptance criteria (sample, traceable)

- AC-1 (M1, ORA-CAP-006): From a warm idle state, pressing the hotkey shows the indicator and begins capture
  within 50 ms (measured).
- AC-2 (M2, ORA-ASR-002/003, ORA-INS-001): For a 30 s dictation into an editor, text appears in the field
  within 500 ms of stop (measured, median of N runs).
- AC-3 (M3, ORA-ASR-003): A synthetic finalization stall results in confirmed text being inserted within
  2.5 s and the tail appearing in the recovery buffer (demonstration).
- AC-4 (M4, ORA-REL-002, ORA-CAP-003): Connecting a headset mid-dictation does not lose confirmed text; the
  session resumes (demonstration).
- AC-5 (ORA-INS-002/007): With focus moved to another app (or a secure field) before insertion, no text is
  inserted into the wrong place and the result is recoverable (demonstration).
- AC-6 (ORA-REC-003): A buffer entry is gone from memory and menu 5 minutes after creation with no user
  interaction (measurement).
- AC-7 (ORA-IND-012): The indicator panel’s frame does not change dimensions as preview text streams in
  (inspection + demonstration).
- AC-8 (ORA-IND-013/014/015): On a notched display the indicator matches notch geometry; on a non-notched
  display it renders as a pill; on display change it recomputes (demonstration across configurations).
- AC-9 (ORA-PRIV-001): With the model present and the network fully disabled, all core functions work; a
  network monitor shows zero egress (measurement).

---

## 15. Build, Tooling & Distribution

- ORA-BLD-001 (MUST): Single app target, Swift 6.x, current Xcode, strict concurrency. No third-party
  packages (M6).
- ORA-BLD-002 (MUST): **Developer ID certificate configured from day 0**, even for personal builds, to keep
  TCC grants stable across rebuilds.
- ORA-BLD-003 (MUST): Release builds are Developer ID signed, Hardened Runtime enabled, and **notarized**;
  distribution is a notarized zip. No auto-update framework.
- ORA-BLD-004 (SHOULD): A headless (non-shipped) test harness MAY exercise the audio→analyzer→insertion path
  without a microphone or user.

---

## 16. Assumptions & Dependencies

- A1. The platform provides an on-device streaming speech analyzer + transcriber with confirmed/volatile
  results and a managed model-asset inventory on macOS 26 (Apple Silicon).
- A2. The platform exposes focused-element access and programmatic text insertion via the Accessibility API,
  and global hotkey registration via the OS.
- A3. Custom-vocabulary biasing is available per-request via `AnalysisContext.contextualStrings` — but only
  on `DictationTranscriber` (see ORA-VOC-002).
- A4. The primary user’s Mac and friends’ Macs meet the platform floor (macOS 26, Apple Silicon).
- A5. Notch geometry is queryable via the documented `NSScreen` APIs.

---

## 17. Out of Scope / Future

- On-device LLM refinement as an **explicit, off-by-default opt-in** that inserts raw text immediately and,
  only if enabled, refines asynchronously and **never** blocks insertion. (Deferred; framework not linked in v1
  per R9.)
- The custom-term correction pass (ORA-VOC-003) built deliberately once real misrecognition data exists.

---

*End of specification.*
