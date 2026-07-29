import AppKit
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
    /// When `lastError` was set — an error is an *event*, not a standing condition, so it stops being
    /// shown once it has outlived its truth (see `recentError`).
    private var lastErrorAt: Date?
    /// A transient end-of-dictation message for the indicator: shown when the outcome was NOT a clean
    /// insert, so "saved to the menu", "heard nothing", and "lost the microphone" are never
    /// indistinguishable from success (ORA-REL-001).
    public private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    /// How long a `lastError` stays worth showing. Past this it is stale, and a live readiness problem
    /// is the more useful thing to surface.
    private static let errorRelevance: TimeInterval = 120

    /// `lastError`, but only while it is still recent.
    public var recentError: String? {
        guard let lastError, let at = lastErrorAt,
              now().timeIntervalSince(at) < Self.errorRelevance else { return nil }
        return lastError
    }

    /// Derived menu-bar glyph (ORA-IND-001).
    public var glyph: IndicatorGlyph { .from(state: state, readiness: readiness) }

    // Confirmed accumulator — the sacred text (ORA-SM-002).
    private var confirmedText: String = ""

    // Collaborators. Audio and insertion are protocol-typed so the state machine can be driven
    // headlessly (see `AudioSource` / `TextInserting`).
    private let audio: any AudioSource
    private let engine: SpeechEngine
    private let inserter: any TextInserting
    public let recovery: RecoveryBuffer
    private let permissions: PermissionsManager
    private let feedback: SoundFeedback
    private let now: @MainActor () -> Date
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
    /// The live engine session, kept so a mid-dictation microphone change can bridge a fresh capture
    /// stream into the SAME transcription instead of starting over.
    private var sessionToken: SpeechEngine.SessionToken?
    /// Microphone failovers used by the current dictation, so a flapping device can't loop.
    private var failoverCount = 0
    private static let maxFailovers = 2
    /// UIDs that already failed during this dictation; excluded from failover device resolution.
    private var failedDeviceUIDs: Set<String> = []
    /// Loudest level seen this dictation. Diagnostic only: it separates "the mic delivered silence"
    /// from "audio arrived but the recognizer returned nothing", which look identical to the user.
    private var peakLevel: Float = 0

    private let debounce: TimeInterval = 0.030            // ORA-ACT-004
    private let maxDuration: TimeInterval = 30 * 60       // ORA-SM-010
    private let finalizationCap: Duration = .milliseconds(2500)  // ORA-ASR-003 / M3

    /// `now` is injectable so error-expiry is testable without wall-clock waits (same idiom as
    /// `RecoveryBuffer`).
    public init(audio: any AudioSource, engine: SpeechEngine, inserter: any TextInserting,
                recovery: RecoveryBuffer, permissions: PermissionsManager, feedback: SoundFeedback,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
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
            Task { @MainActor in self?.handleCaptureFailure(reason: reason) }
        }
    }

    /// Capture died mid-dictation (device unplugged, session faulted, buffers stopped arriving).
    ///
    /// The confirmed text lives here, outside the audio and engine object lifecycles (ORA-SM-002),
    /// precisely so this is survivable — so the FIRST response is to move to another microphone and
    /// keep the same dictation going (ORA-CAP-003 / E6). Only when there is nowhere to go do we end
    /// the dictation, and then we end it *properly*: finalize and insert, exactly like a normal stop.
    private func handleCaptureFailure(reason: String) {
        // Only an ACTIVE recording is affected. During `.finalizing`/`.inserting` capture is already
        // stopped, so a late/stale mic-loss callback must NOT run — it would divert the
        // just-transcribed text to recovery instead of inserting it (ORA-CAP-022).
        guard state == .recording else { return }
        Log.session.error("Capture failure: \(reason)")
        if attemptFailover() { return }
        setError(reason)
        Task { await self.finish(lossReason: reason) }
    }

    /// Move the live dictation onto whatever microphone is usable now, keeping the SAME analyzer
    /// session — the engine's token is per-transcription, not per-capture, so a fresh capture stream
    /// bridges straight into it and the confirmed text is untouched. Device re-resolution is
    /// `resolveUID`'s existing job: a pinned mic that vanished falls back to the default here, and
    /// re-engages on its own when it comes back.
    ///
    /// A second or two of speech is lost across the switch — a seam in the transcript, versus losing
    /// the dictation. Bounded, so a device that flaps can't spin here forever.
    private func attemptFailover() -> Bool {
        guard failoverCount < Self.maxFailovers,
              let token = sessionToken,
              let format = engine.inputFormat else { return false }

        // Retire the device that just failed BEFORE re-resolving. A mic that dies without faulting the
        // session still enumerates and still looks usable, so without this the resolver hands back the
        // same dead device and every attempt is spent on it.
        if let failed = audio.currentDeviceUID { failedDeviceUIDs.insert(failed) }
        audio.stop()
        bridgeTask?.cancel(); bridgeTask = nil

        let stream: AsyncStream<AnalyzerInput>
        do { stream = try audio.start(outputFormat: format, excluding: failedDeviceUIDs) }
        catch {
            // Only excluded devices left ⇒ there is genuinely nowhere to go; the caller ends the
            // dictation properly rather than burning the remaining attempts.
            Log.session.error("Failover found no usable microphone: \(error.localizedDescription)")
            return false
        }
        failoverCount += 1
        bridgeTask = Task.detached { [engine] in
            for await input in stream { engine.feed(input, for: token) }
        }
        // Deliberately NO user-facing notice: `notice` is a terminal message that replaces the live
        // preview and hides the elapsed timer, so raising one mid-session reads as "the dictation just
        // ended" — the exact signal failover exists to avoid. A working failover should be seamless.
        Log.session.notice("Failed over to another microphone; session continues")
        return true
    }

    /// Abort without finalizing — for a session that never had a transcriber attached, so there is
    /// nothing to finalize or insert.
    private func abortSession(reason: String) {
        guard state == .recording else { return }
        Log.session.error("Session aborted: \(reason)")
        teardownCapture()
        engine.endSession()
        if !confirmedText.isEmpty { recovery.add(confirmedText, reason: .noTarget) }
        confirmedText = ""
        volatilePreview = ""
        setError(reason)
        state = .idle
        sessionToken = nil
        // An abort that only logged left the user talking into a dead session with no cue and no
        // message. Sound it and hold the reason on-screen briefly (E5 / ORA-REL-001).
        feedback.playError()
        showNotice(reason)
    }

    /// Record a failure reason, timestamped so it can go stale (see `recentError`).
    ///
    /// `internal` rather than `private` only so tests can provoke an error mid-session without
    /// ending it — every real caller is in this file.
    func setError(_ reason: String) {
        lastError = reason
        lastErrorAt = now()
    }

    private func clearError() {
        lastError = nil
        lastErrorAt = nil
    }

    /// Hold `text` in the indicator briefly after the session ends, and speak it to VoiceOver — the
    /// panel is a decorative overlay VoiceOver never focuses.
    private func showNotice(_ text: String, for duration: Duration = .milliseconds(1600)) {
        notice = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Drop any showing notice immediately (a new dictation supersedes the last one's outcome).
    private func clearNotice() {
        noticeTask?.cancel(); noticeTask = nil
        notice = nil
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
            Task { await finish() }
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
        clearError()          // the user resolved the session deliberately; nothing is wrong now
        clearNotice()
        sessionToken = nil
        state = .idle             // no insertion, no recovery entry
    }

    // MARK: Recording

    private func startRecording() async {
        let began = ContinuousClock.now
        defer { starting = false }
        guard state == .idle else { return }
        guard engine.isWarm, let format = engine.inputFormat else {
            Log.session.error("Cannot start: engine not warm")
            // As in the `beginSession` failure below: only claim a MODEL problem when the model really
            // is the problem. An engine that failed to warm with the asset present is a transient
            // fault, and `.needsModel(.installed)` would disable the hotkey outright.
            let status = await engine.modelStatus()
            if status != .installed { readiness = .needsModel(status) }
            else { setError("Speech engine isn’t ready yet — try again.") }
            feedback.playError()
            return
        }
        // TCC mic access can be revoked after launch; capturing without it doesn't throw — it just
        // delivers silence. Re-check O(1) so a denied mic surfaces as a permission problem rather than
        // a silent dead-air recording (ORA-CAP-018).
        guard permissions.microphoneGranted else {
            Log.session.error("Cannot start: microphone permission not granted")
            readiness = .needsPermission(permissions.missing())
            setError("Microphone access is off. Enable it in System Settings.")
            feedback.playError()
            return
        }

        clearNotice()   // this dictation supersedes the previous one's outcome message
        failoverCount = 0
        failedDeviceUIDs = []   // a fresh dictation re-trusts every device
        peakLevel = 0
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
            setError("Couldn’t start the microphone.")
            feedback.playError()
            return
        }

        // Enter recording ONLY after capture actually started (ORA-SM-004).
        state = .recording
        startInstant = ContinuousClock.now
        clearError()
        DebugLog.stage("start→capturing", ms: (ContinuousClock.now - began).milliseconds)   // M1 (ORA-PERF-004)
        feedback.playStart()                                      // non-blocking cue (overlapped)

        let token = await engine.beginSession()

        // `beginSession` is a suspension point: a second hotkey press during it runs finish() →
        // teardownCapture concurrently. If we resumed here on a torn-down session we'd wire an orphan
        // bridge/tick that feeds audio into the engine AFTER endSession (duplicate/garbled text) and
        // ticks past teardown. Bail if the session is no longer recording (ORA-SM-014).
        guard state == .recording else {
            // REAP the session we just started. Whoever ended the dictation called `endSession()`
            // before `beginSession` resumed, so its analyzer, results task and input continuation were
            // installed after that teardown and now belong to nobody — and `.processLifetime` model
            // retention means an orphan holds the model until some later `beginSession` happens to
            // tear it down. `toggle()`'s `starting` guard means no NEWER session can exist here, so
            // this can only be reaping our own.
            if token != nil { engine.endSession() }
            sessionToken = nil
            return
        }

        // No transcriber attached ⇒ every buffer would be silently discarded while the indicator,
        // timer and start cue all claim a live dictation. Fail loudly instead (ORA-REL-001).
        guard let token else {
            // Only downgrade readiness if the MODEL is actually the problem. `beginSession` also
            // returns nil for a transient engine hiccup (prepare/start throwing, a busy speech daemon),
            // and `.needsModel(.installed)` still fails `canStartDictation` — which would kill the
            // hotkey and point Setup at downloading an already-installed model, with recovery only on
            // the next menu-open. The abort's own error + notice already explain the failure.
            let status = await engine.modelStatus()
            if status != .installed { readiness = .needsModel(status) }
            abortSession(reason: "Couldn’t start transcription.")
            return
        }
        sessionToken = token

        // Bridge audio → engine (the audio consumer). Detached so buffers never hop the main actor
        // (the engine's `feed` is nonisolated). The engine's own single results task (ORA-CC-003)
        // feeds this coordinator back via SpeechResultSink. The token makes a bridge that outlives its
        // session a no-op rather than a source of cross-session bleed.
        bridgeTask = Task.detached { [engine] in
            for await input in stream { engine.feed(input, for: token) }
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

    /// The ONE terminal path: finalize whatever was said and place it.
    ///
    /// Both ways a dictation ends come through here — the user stopping it, and capture dying with no
    /// microphone left to fail over to. They previously existed as two copies of the same nine steps,
    /// and the copies drifted: the capture-loss path dumped confirmed text straight into the recovery
    /// menu, throwing away a perfectly good paste into a target that was still focused, which is the
    /// exact mistake the finalization-timeout path had already made once. One definition, one place to
    /// change the stop sequence.
    ///
    /// `lossReason` is the only real difference in behaviour: it selects a discard teardown (the
    /// device is gone, so there is nothing left to drain) and is surfaced to the user at the end.
    private func finish(lossReason: String? = nil) async {
        guard state == .recording else { return }
        let stopped = ContinuousClock.now
        state = .finalizing
        if lossReason != nil {
            teardownCapture()             // discard: the device is gone, nothing more will arrive
        } else {
            await teardownCaptureDraining()   // graceful stop: DRAIN trailing buffers (don't drop them)
        }

        let finished = await engine.finalize(within: finalizationCap)
        DebugLog.stage("stop→final", ms: (ContinuousClock.now - stopped).milliseconds)   // M3
        // Wait until the confirmed accumulator stops growing (the results task delivers the flushed
        // finals asynchronously). State stays `.finalizing` here, so those late finals ARE accepted
        // by `speechDidConfirm` — this closes the drop-the-tail race. Bounded ≤ ~250 ms (inside M2).
        await drainConfirmed(upTo: .milliseconds(250))

        // Tail read AFTER the drain — see `resolveText`.
        let finalText = TranscriptCleaner.clean(Self.resolveText(confirmed: confirmedText,
                                                                 tail: volatilePreview,
                                                                 finished: finished))
        volatilePreview = ""
        engine.endSession()   // drop anything still unfinalized so it can't cross into next session

        state = .inserting
        await insert(finalText, timedOut: !finished, lossReason: lossReason)
        DebugLog.stage("stop→inserted", ms: (ContinuousClock.now - stopped).milliseconds)   // M2
        state = .idle
        startInstant = nil
        sessionToken = nil
    }

    /// Terminal step. Every exit gives the user a DISTINCT signal: the success cue only for a real
    /// insert, and an explicit on-screen reason otherwise. Previously the deferred-to-recovery path
    /// played the identical success cue and the two "nothing happened" cases were silent — so in the
    /// supported accessibility-missing degraded mode (E2) every dictation sounded exactly like success
    /// while quietly landing in a menu whose entries the 5-minute TTL then deleted.
    /// `timedOut` records that `text` includes an unfinalized tail (ORA-ASR-003 / E7), so a failure to
    /// insert is filed under the reason the user can act on.
    /// `lossReason`, when set, means the dictation ended because capture died rather than because the
    /// user stopped it — the text still gets placed, but the user is told what happened to the mic.
    private func insert(_ text: String, timedOut: Bool, lossReason: String? = nil) async {
        guard !text.isEmpty else { emptyResultFeedback(lossReason); return }
        guard let target else {
            // No target at all — the one case where text genuinely cannot be placed (M4).
            let reason: RecoveryReason = timedOut ? .finalizationTimeout : .noTarget
            recovery.add(Self.standalone(text), reason: reason)
            deferredFeedback(reason)
            return
        }

        let outcome = await inserter.insert(text, into: target,
                                            accessibilityGranted: permissions.accessibilityGranted)
        switch outcome {
        case .inserted:
            feedback.playStop()                      // the completion cue means INSERTED, nothing else
            recovery.add(Self.standalone(text), reason: .inserted)   // keep briefly so a stray paste is recoverable
            // The text landed, but the mic still died — say so, and KEEP the error: clearing it here
            // would erase the record of a hardware problem the user still has, just because this
            // dictation happened to survive it.
            if let lossReason { showNotice(lossReason) }
            else { clearError() }                    // a clean dictation clears any prior failure
        case .deferredToRecovery(let reason):
            recovery.add(Self.standalone(text), reason: reason)      // no text lost (M4)
            Log.insert.notice("Routed to recovery: \(String(describing: reason))")
            deferredFeedback(reason)
        }
    }

    /// The text a finished session should place, from the confirmed accumulator plus whatever volatile
    /// tail is left.
    ///
    /// `tail` MUST be read *after* `drainConfirmed`, never snapshotted before it. Late finals arriving
    /// during the drain are appended to `confirmed` and clear `volatilePreview` (see
    /// `speechDidConfirm`), so a pre-drain snapshot names text that is now already confirmed — joining
    /// it would insert those words a second time, into the user's document.
    static func resolveText(confirmed: String, tail: String, finished: Bool) -> String {
        // Finalization timed out ⇒ the leftover volatile tail is the best text we have for the part the
        // recognizer never confirmed, so it goes in rather than being withheld (ORA-ASR-003).
        if !finished { return joined(confirmed, tail) }
        // Clean finalize ⇒ `confirmed` is authoritative; the tail is only a fallback for a session that
        // confirmed nothing at all.
        return confirmed.isEmpty ? tail : confirmed
    }

    /// Text bound for the recovery menu stands alone — there is no surrounding sentence for it to
    /// continue — so it always gets a capital, unlike text pasted into a field (see `SentenceContext`).
    private static func standalone(_ text: String) -> String { TranscriptCleaner.capitalized(text) }

    /// Join two fragments, inserting a separating space only when the boundary needs one. The single
    /// definition of that rule: `speechDidConfirm` accumulates confirmed segments through it, and
    /// `resolveText` appends the volatile tail through it, so the two cannot drift.
    private static func joined(_ head: String, _ tail: String) -> String {
        guard !tail.isEmpty else { return head }
        guard !head.isEmpty else { return tail }
        if let last = head.last, !last.isWhitespace, let first = tail.first, !first.isWhitespace {
            return head + " " + tail
        }
        return head + tail
    }

    /// Text was saved but not inserted: name the reason on-screen and point at where it went.
    private func deferredFeedback(_ reason: RecoveryReason) {
        feedback.playError()
        showNotice("\(reason.label) — saved to the menu")
    }

    /// A completed dictation that produced no text at all. Silence here reads as a broken app. When
    /// capture died, the mic is the real explanation — "didn't catch anything" would misdirect.
    ///
    /// Logged, not just shown: "recorded fine but produced nothing" is the one outcome that otherwise
    /// leaves NO trace in the unified log, which makes it the hardest failure to diagnose after the
    /// fact — exactly when a user reports "transcription isn't working".
    private func emptyResultFeedback(_ lossReason: String? = nil) {
        Log.session.notice("Dictation produced no text (elapsed \(self.elapsed, format: .fixed(precision: 1))s, peak level \(self.peakLevel, format: .fixed(precision: 3)))")
        // A soft falling tone, not the error sound: hearing nothing is a benign outcome, not a fault.
        // Capture DYING is a fault and keeps `playError`.
        if lossReason == nil { feedback.playNothingHeard() } else { feedback.playError() }
        showNotice(lossReason ?? "Didn’t catch anything")
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
                self.peakLevel = max(self.peakLevel, self.audioLevel)
                if self.elapsed >= self.maxDuration {
                    // Hand off to a FRESH task and leave the loop. Calling finish() inline ran
                    // the whole stop path inside tickTask — which stopTimersAndTaps cancels — so every
                    // `try? await Task.sleep` on that path threw CancellationError immediately and was
                    // swallowed: drainConfirmed collapsed to zero-elapsed iterations (dropping the late
                    // finals it exists to collect) and the terminal settle delay was skipped. This keeps
                    // auto-stop byte-identical to the manual stop path, as E14 claims (ORA-SM-010).
                    Task { @MainActor [weak self] in await self?.finish() }
                    break
                }
                self.checkCaptureAlive()
            }
        }
    }

    /// Watchdog for capture that dies without an error (ORA-REL-001).
    ///
    /// The runtime-error notification only fires when the session itself faults, and it is further
    /// gated on `!isRunning` — but a session whose input device is yanked commonly has the input
    /// removed while still reporting `isRunning`, delivering zero buffers and no error. Nothing else
    /// tracked whether audio was actually arriving, so a dead mic looked exactly like a live one until
    /// the 30-minute cap. Silence still produces buffers, so this trips only on genuine capture death —
    /// it is NOT the silence-based auto-stop ORA-SM-011 forbids.
    ///
    /// Gated on `.recording`: during `.finalizing` capture is deliberately stopped, and firing there
    /// would divert the just-transcribed text to recovery (ORA-CAP-022).
    private func checkCaptureAlive() {
        guard state == .recording, let silent = audio.secondsSinceLastBuffer else { return }
        // Two budgets, not one. Before the first buffer ever arrives we are watching a device WAKE UP:
        // Bluetooth HFP link setup and Continuity/iPhone-mic activation routinely take 1–3 s, and
        // applying the steady-state limit there kills a microphone that was about to work (and then
        // re-opens the same slow device on failover, twice). Once audio has flowed, silence really
        // does mean the device died, so the tight limit applies.
        let limit = audio.hasDeliveredAudio ? Self.captureStallLimit : Self.captureStartupLimit
        guard silent > limit else { return }
        handleCaptureFailure(reason: "Lost the microphone.")
    }

    /// How long capture may deliver nothing, once it has delivered something, before it counts as
    /// dead. Comfortably above any normal buffer interval (~10–100 ms).
    private static let captureStallLimit: TimeInterval = 2.5
    /// How long a device gets to produce its FIRST buffer before we give up on it.
    private static let captureStartupLimit: TimeInterval = 8.0

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
        confirmedText = Self.joined(confirmedText, text)
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
                                level: audioLevel, previewTail: tail, isNotch: false,
                                notice: notice)
    }

    /// True while the indicator has something to say — an active session, or a terminal notice being
    /// held after one ended.
    public var indicatorVisible: Bool { state != .idle || notice != nil }
}
