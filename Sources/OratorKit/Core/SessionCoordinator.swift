import Foundation
import Speech
import Observation

/// The single owner of the dictation lifecycle (§7.2). Runs on the main actor and processes one
/// event at a time (ORA-SM-001); audio and engine work happen off-main and deliver results *to*
/// the coordinator, never mutating its state directly.
///
/// **Confirmed text lives here** (ORA-SM-002), outside the audio/engine object lifecycles, so it
/// survives any reconfiguration and is recoverable even if insertion never happens.
@MainActor
@Observable
public final class SessionCoordinator: SpeechResultSink {
    // Observable UI state (read by the indicator + status item).
    public private(set) var state: SessionState = .idle
    public private(set) var readiness: Readiness = .ready
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var audioLevel: Float = 0
    /// The volatile tail for the live preview only (ORA-ASR-004); never inserted.
    public private(set) var volatilePreview: String = ""
    /// A legible reason for the most recent failure (E5), surfaced in the menu tooltip.
    public private(set) var lastError: String?

    /// Derived menu-bar glyph (ORA-IND-001).
    public var glyph: IndicatorGlyph { .from(state: state, readiness: readiness) }

    // Confirmed accumulator — the sacred text (ORA-SM-002).
    private var confirmedText: String = ""

    // Collaborators.
    private let audio: AudioCapture
    private let engine: SpeechEngine
    private let inserter: TextInserter
    public let recovery: RecoveryBuffer
    private let permissions: PermissionsManager
    private let feedback: SoundFeedback
    private var escapeTap: EscapeTap?

    // Session bookkeeping.
    private var target: TargetContext?
    /// Monotonic recording start instant — drives `elapsed` and the max-duration auto-stop. Monotonic
    /// (not wall-clock Date) so an NTP/DST/manual clock jump can't skew the timer or mis-fire the
    /// auto-stop (ORA-SM-013).
    private var startInstant: ContinuousClock.Instant?
    private var lastToggle: Date?
    /// Set synchronously in `toggle()` before the async start, so a second press during start-up
    /// cannot re-enter `startRecording` (closes the reentrancy window; ORA-SM-001/003).
    private var starting = false
    private var bridgeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    private let debounce: TimeInterval = 0.030            // ORA-ACT-004
    private let maxDuration: TimeInterval = 30 * 60       // ORA-SM-010
    private let finalizationCap: Duration = .milliseconds(2500)  // ORA-ASR-003 / M3

    public init(audio: AudioCapture, engine: SpeechEngine, inserter: TextInserter,
                recovery: RecoveryBuffer, permissions: PermissionsManager, feedback: SoundFeedback) {
        self.audio = audio
        self.engine = engine
        self.inserter = inserter
        self.recovery = recovery
        self.permissions = permissions
        self.feedback = feedback
        engine.sink = self
        // If capture can't be resumed after a device change, abort cleanly rather than sit in
        // `.recording` with a dead mic and a live indicator (ORA-REL-001 "no stuck state").
        audio.onUnrecoverableFailure = { [weak self] reason in
            Task { @MainActor in self?.abortSession(reason: reason) }
        }
    }

    /// Abort an in-progress dictation, preserving already-confirmed text in recovery (never lost).
    private func abortSession(reason: String) {
        // Only an ACTIVE recording is abortable. During `.finalizing` capture is already stopped, so a
        // late/stale mic-loss callback must NOT run — it would divert the just-transcribed text to
        // recovery instead of inserting it (ORA-CAP-022).
        guard state == .recording else { return }
        Log.session.error("Session aborted: \(reason)")
        teardownCapture()
        engine.endSession()
        if !confirmedText.isEmpty { recovery.add(confirmedText, reason: .noTarget) }
        confirmedText = ""
        volatilePreview = ""
        lastError = reason
        state = .idle
    }

    // MARK: Readiness (ORA-PERM-002/003)

    /// Recompute readiness. Called at launch and whenever the app regains focus, so a grant made in
    /// System Settings takes effect without a restart, and a stale grant is surfaced.
    public func refreshReadiness() async {
        let missing = permissions.missing()
        // Microphone is record-blocking; without it there is nothing to transcribe.
        if missing.contains(.microphone) { readiness = .needsPermission(missing); return }
        // Accessibility being absent does NOT block recording — E2 requires recording to still work,
        // with insertion routed to the recovery buffer. It is surfaced (menu/onboarding) but the
        // hotkey stays live; `Readiness.canStartDictation` ignores an accessibility-only gap.
        let model = await engine.modelStatus()
        switch model {
        case .installed:
            if !missing.isEmpty {
                readiness = .needsPermission(missing)     // accessibility-only: still can dictate
            } else {
                readiness = SecureInput.isGloballyActive ? .degradedHotkey : .ready
            }
        case .missing, .unsupported, .failed, .downloading:
            readiness = .needsModel(model)
        }
    }

    // MARK: Hotkey toggle (ORA-ACT-001)

    /// First press starts a dictation; second press stops it (toggle mode). Debounced (ORA-ACT-004),
    /// busy-guarded (ORA-SM-003), and fail-safe when not ready (ORA-PERM-003).
    public func toggle() {
        let now = Date()
        if let last = lastToggle, now.timeIntervalSince(last) < debounce { return }
        lastToggle = now

        switch state {
        case .idle:
            guard !starting else { return }   // start already in flight (ORA-SM-003)
            guard readiness.canStartDictation else {
                feedback.playError()
                Log.session.notice("Hotkey ignored: not ready (\(String(describing: self.readiness)))")
                return
            }
            starting = true                    // synchronous guard before the async start
            Task { await startRecording() }
        case .recording:
            Task { await stopAndInsert() }
        case .finalizing, .inserting:
            // Busy guard (ORA-SM-003): ignore.
            Log.session.debug("Hotkey ignored: busy (\(self.state.rawValue))")
        }
    }

    /// Escape cancels an in-progress dictation, discarding everything (ORA-ACT-003 / ORA-SM-012).
    public func cancel() {
        guard state == .recording else { return }
        Log.session.notice("Cancel: discarding audio + text, no insertion")
        teardownCapture()
        confirmedText = ""
        volatilePreview = ""
        engine.endSession()   // drop unfinalized audio so it can't bleed into the next session
        state = .idle             // no insertion, no recovery entry
    }

    // MARK: Recording

    private func startRecording() async {
        let began = ContinuousClock.now
        defer { starting = false }
        guard state == .idle else { return }
        guard engine.isWarm, let format = engine.inputFormat else {
            Log.session.error("Cannot start: engine not warm")
            readiness = .needsModel(await engine.modelStatus())
            feedback.playError()
            return
        }
        // TCC mic access can be revoked after launch; capturing without it doesn't throw — it just
        // delivers silence. Re-check O(1) so a denied mic surfaces as a permission problem rather than
        // a silent dead-air recording (ORA-CAP-018).
        guard permissions.microphoneGranted else {
            Log.session.error("Cannot start: microphone permission not granted")
            readiness = .needsPermission(permissions.missing())
            lastError = "Microphone access is off. Enable it in System Settings."
            feedback.playError()
            return
        }

        target = TargetContext.capture()
        confirmedText = ""
        volatilePreview = ""
        audioLevel = 0
        elapsed = 0        // reset BEFORE the indicator expands so it never flashes the prior session's time

        // Start capture FIRST to meet the hotkey→capturing budget (M1 ≤50 ms); the start cue plays
        // concurrently rather than gating it. Resolves FBK-001(SHOULD) vs M1(MUST) toward the MUST:
        // a subtle cue that may bleed slightly is acceptable; a 180 ms stall is not.
        let stream: AsyncStream<AnalyzerInput>
        do {
            stream = try audio.start(outputFormat: format)
        } catch {
            // Capture failed to start ⇒ stay idle, no indicator, legible reason (ORA-SM-004 / E5).
            Log.session.error("Audio start failed: \(error.localizedDescription)")
            lastError = "Couldn’t start the microphone."
            feedback.playError()
            return
        }

        // Enter recording ONLY after capture actually started (ORA-SM-004).
        state = .recording
        startInstant = ContinuousClock.now
        lastError = nil
        DebugLog.stage("start→capturing", ms: (ContinuousClock.now - began).milliseconds)   // M1 (ORA-PERF-004)
        feedback.playStart()                                      // non-blocking cue (overlapped)
        await engine.beginSession(vocabulary: Settings.shared.vocabulary)  // set vocab before feeding

        // `beginSession` is a suspension point: a second hotkey press during it runs stopAndInsert →
        // teardownCapture concurrently. If we resumed here on a torn-down session we'd wire an orphan
        // bridge/tick that feeds audio into the engine AFTER endSession (duplicate/garbled text) and
        // ticks past teardown. Bail if the session is no longer recording (ORA-SM-014).
        guard state == .recording else { return }

        // Bridge audio → engine (the audio consumer). Detached so buffers never hop the main actor
        // (the engine's `feed` is nonisolated). The engine's own single results task (ORA-CC-003)
        // feeds this coordinator back via SpeechResultSink.
        bridgeTask = Task.detached { [engine] in
            for await input in stream { engine.feed(input) }
        }
        startTicking()
        // Defer the Escape event-tap: creating a CGEvent tap is synchronous main-thread work that
        // hitches the indicator's expand animation. Nobody hits Escape in the first ~third of a second,
        // and the menu's "Cancel Dictation" is the fallback until it's armed. Delay tracks the expand
        // timeline (shared constants) so the tap arms just after the spring settles.
        let escapeDelay = IndicatorMetrics.expandDuration + IndicatorMetrics.settleBuffer
        DispatchQueue.main.asyncAfter(deadline: .now() + escapeDelay) { [weak self] in
            guard let self, self.state == .recording, self.escapeTap == nil else { return }
            self.installEscapeTap()
        }
    }

    private func stopAndInsert() async {
        guard state == .recording else { return }
        let stopped = ContinuousClock.now
        state = .finalizing
        // Snapshot the volatile tail before teardown/finalize: fallback if a clean finalize yields no confirmed text.
        let tailAtStop = volatilePreview
        await teardownCaptureDraining()   // graceful stop: DRAIN trailing buffers (don't drop them)

        let finished = await engine.finalize(within: finalizationCap)
        DebugLog.stage("stop→final", ms: (ContinuousClock.now - stopped).milliseconds)   // M3
        // Wait until the confirmed accumulator stops growing (the results task delivers the flushed
        // finals asynchronously). State stays `.finalizing` here, so those late finals ARE accepted
        // by `speechDidConfirm` — this closes the drop-the-tail race. Bounded ≤ ~250 ms (inside M2).
        await drainConfirmed(upTo: .milliseconds(250))

        var finalText = confirmedText
        if finished, finalText.isEmpty { finalText = tailAtStop }   // fallback: nothing confirmed
        finalText = TranscriptCleaner.clean(finalText)              // strip stray leading punctuation, fix casing
        let unfinalizedTail = finished ? "" : tailAtStop
        volatilePreview = ""
        engine.endSession()   // drop anything still unfinalized so it can't cross into next session

        state = .inserting
        await insert(finalText, tail: unfinalizedTail)
        DebugLog.stage("stop→inserted", ms: (ContinuousClock.now - stopped).milliseconds)   // M2
        state = .idle
        startInstant = nil
    }

    private func insert(_ text: String, tail: String) async {
        // Park the unfinalized tail FIRST, before any early return, so it is never lost even when
        // there is no target (ORA-ASR-003 / ORA-REC-004 / E7 / M4).
        if !tail.isEmpty { recovery.add(tail, reason: .finalizationTimeout) }

        guard let target else {
            if !text.isEmpty { recovery.add(text, reason: .noTarget) }
            return
        }
        guard !text.isEmpty else { return }

        let outcome = await inserter.insert(text, into: target,
                                            accessibilityGranted: permissions.accessibilityGranted)
        feedback.playStop()   // completion cue on either outcome, fired immediately (ORA-INS-005)
        switch outcome {
        case .inserted:
            recovery.add(text, reason: .inserted)    // keep briefly so a stray paste is recoverable
        case .deferredToRecovery(let reason):
            recovery.add(text, reason: reason)       // no text lost (M4)
            Log.insert.notice("Routed to recovery: \(String(describing: reason))")
        }
    }

    // MARK: Auto-stop (ORA-SM-010) + elapsed clock + waveform level

    /// The single 100 ms UI tick while recording: elapsed time, the polled audio level (the tap
    /// thread just writes a lock-boxed scalar — no per-buffer Tasks), and the max-duration stop.
    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let start = self.startInstant else { break }
                self.elapsed = (ContinuousClock.now - start).milliseconds / 1000   // monotonic seconds
                self.audioLevel = self.audio.currentLevel
                if self.elapsed >= self.maxDuration {
                    await self.stopAndInsert()        // auto-stop as a normal stop (E14)
                    break
                }
            }
        }
    }

    /// Discard-path teardown (cancel/abort): drop the bridge — its unconsumed buffers are intentionally
    /// thrown away.
    private func teardownCapture() {
        audio.stop()
        bridgeTask?.cancel(); bridgeTask = nil
        stopTimersAndTaps()
    }

    /// Graceful-stop teardown: finish the stream, then DRAIN the bridge so audio captured just before
    /// key-release is fed to the engine before `finalize()`. Cancelling (as the discard path does)
    /// would short-circuit the consumer and drop those trailing buffers — the audio would never be
    /// transcribed (ORA-CAP-023). Bounded by the current bridge backlog (the tail after finish()).
    private func teardownCaptureDraining() async {
        audio.stop()                // continuation.finish() → the bridge loop ends once drained
        await bridgeTask?.value      // consume all buffered inputs into engine.feed() first
        bridgeTask = nil
        stopTimersAndTaps()
    }

    /// The teardown shared by both stop paths: the UI tick and the Escape tap (only bridge handling
    /// differs — cancel vs drain).
    private func stopTimersAndTaps() {
        tickTask?.cancel(); tickTask = nil
        escapeTap?.stop(); escapeTap = nil
    }

    private func installEscapeTap() {
        let tap = EscapeTap { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        escapeTap = tap
        if !tap.start() {
            // Tap unavailable (denied / global secure input). The always-present "Cancel Dictation"
            // menu item is the degraded fallback (E10).
            Log.session.notice("Escape tap unavailable — menu cancel is the fallback")
        }
    }

    /// Wait until the confirmed accumulator stops growing, so late finals delivered by the results
    /// task are reflected before we read `confirmedText`. Robust to the tail already being empty
    /// (unlike polling volatile), and bounded so a stalled engine can't hang stop.
    private func drainConfirmed(upTo limit: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        var previous = -1
        var stableTicks = 0
        while ContinuousClock.now < deadline {
            let count = confirmedText.count
            if count == previous {
                stableTicks += 1
                if stableTicks >= 2 { break }   // unchanged across two ticks ⇒ drained
            } else {
                stableTicks = 0
                previous = count
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    // MARK: SpeechResultSink (called in order by the engine's single task, ORA-CC-003)

    public func speechDidConfirm(_ text: String) {
        guard state == .recording || state == .finalizing else { return }
        if let last = confirmedText.last, !last.isWhitespace,
           let first = text.first, !first.isWhitespace {
            confirmedText += " "
        }
        confirmedText += text
        volatilePreview = ""
    }

    public func speechDidReviseVolatile(_ text: String) {
        guard state == .recording else { return }
        volatilePreview = text
    }

    // MARK: Indicator content

    /// A snapshot for rendering the indicator (ORA-IND-010). The preview shows the *tail* of the
    /// live text (confirmed + volatile); the panel never resizes (ORA-IND-012). `isNotch` is decided
    /// by the controller from the active screen, so it is left `false` here and overridden there.
    public func indicatorContent() -> IndicatorContent {
        let tail = [confirmedText, volatilePreview].filter { !$0.isEmpty }.joined(separator: " ")
        return IndicatorContent(state: state, elapsed: elapsed,
                                level: audioLevel, previewTail: tail, isNotch: false)
    }
}
