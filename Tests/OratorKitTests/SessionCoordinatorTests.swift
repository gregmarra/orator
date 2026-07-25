import XCTest
@preconcurrency import AVFoundation
import Speech
@testable import OratorKit

// MARK: - Stand-ins

/// An audio source that starts cleanly and produces no buffers, letting a test decide exactly when
/// capture "dies".
///
/// Models the REAL `AudioCapture` on the two points the watchdog depends on: a successful `start`
/// clears the stall (real capture reseeds its buffer clock, so a failover genuinely buys another full
/// budget — a stub that stayed stalled would drive a rapid-fire cascade hardware cannot produce), and
/// device UIDs honour the failover exclusion set.
@MainActor
private final class StubAudio: AudioSource {
    var currentLevel: Float = 0
    var onUnrecoverableFailure: (@Sendable (String) -> Void)?
    /// Seconds of silence to report. `start` resets it, mirroring the real clock reseed.
    var stallSeconds: TimeInterval = 0
    var hasDeliveredAudio = true
    var throwOnStart: Error?
    /// UIDs this stub can hand out, in preference order; `start` picks the first not excluded.
    var availableUIDs: [String] = ["mic-a", "mic-b"]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var excludedOnLastStart: Set<String> = []
    private(set) var currentDeviceUID: String?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var running = false

    var secondsSinceLastBuffer: TimeInterval? { running ? stallSeconds : nil }

    func start(outputFormat: AVAudioFormat, excluding: Set<String>) throws -> AsyncStream<AnalyzerInput> {
        excludedOnLastStart = excluding
        if let throwOnStart { throw throwOnStart }
        // Only excluded devices left ⇒ the same signal real capture gives (ORA-CAP-006).
        guard let uid = availableUIDs.first(where: { !excluding.contains($0) }) else {
            throw AudioCapture.CaptureError.noInputDevice
        }
        currentDeviceUID = uid
        startCount += 1
        running = true
        stallSeconds = 0            // a fresh session restarts the watchdog budget, as real capture does
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        return stream
    }

    func stop() {
        guard running else { return }
        stopCount += 1
        running = false
        currentDeviceUID = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Returns a scripted outcome and records what it was asked to insert — crucially, it never posts a
/// real CGEvent ⌘V, so the suite can't paste into whatever app is frontmost.
@MainActor
private final class StubInserter: TextInserting {
    var outcome: InsertionOutcome = .inserted
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String, into target: TargetContext,
                accessibilityGranted: Bool) async -> InsertionOutcome {
        insertedTexts.append(text)
        return outcome
    }
}

@MainActor
private final class FakePermissions: PermissionsManager {
    var mic = true
    var accessibility = true
    override var microphoneGranted: Bool { mic }
    override var accessibilityGranted: Bool { accessibility }
}

/// Silences the suite and records which cues fired — the terminal-feedback contract is the behaviour
/// under test, not a side effect.
private final class SpyFeedback: SoundFeedback, @unchecked Sendable {
    enum Cue: Equatable { case start, stop, error }
    private(set) var cues: [Cue] = []
    override func playStart() { cues.append(.start) }
    override func playStop() { cues.append(.stop) }
    override func playError() { cues.append(.error) }
}

// MARK: - Tests

/// `SessionCoordinator` owns every ORA-SM/ORA-ACT requirement and had no tests at all, because its
/// collaborators were concrete final classes (and `TextInserter` posts a real ⌘V). These drive the
/// state machine headlessly through the `AudioSource`/`TextInserting` seams.
///
/// Tests that need a live analyzer skip when the en-US model isn't installed, matching the existing
/// end-to-end tests.
final class SessionCoordinatorTests: XCTestCase {

    @MainActor
    private struct Rig {
        let coordinator: SessionCoordinator
        let audio: StubAudio
        let inserter: StubInserter
        let permissions: FakePermissions
        let feedback: SpyFeedback
        let recovery: RecoveryBuffer
    }

    @MainActor
    private func makeRig() async throws -> Rig {
        let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
        let status = await engine.modelStatus()
        try XCTSkipUnless(status == .installed, "en-US model not installed on this host")
        try await engine.warmUp()

        let audio = StubAudio()
        let inserter = StubInserter()
        let permissions = FakePermissions()
        let feedback = SpyFeedback()
        let recovery = RecoveryBuffer()
        let coordinator = SessionCoordinator(audio: audio, engine: engine, inserter: inserter,
                                             recovery: recovery, permissions: permissions,
                                             feedback: feedback)
        return Rig(coordinator: coordinator, audio: audio, inserter: inserter,
                   permissions: permissions, feedback: feedback, recovery: recovery)
    }

    /// Let the coordinator's `Task { await startRecording() }` (and friends) run to completion.
    @MainActor
    private func settle(_ ms: Int = 250) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Wait for the session to return to `.idle`, then hand back control immediately. Needed for any
    /// assertion about `notice`, which is deliberately transient (~1.6 s) — a fixed long sleep would
    /// race the notice's own expiry and read nil for the wrong reason.
    @MainActor
    private func waitUntilIdle(_ coordinator: SessionCoordinator, timeoutMs: Int = 6000) async {
        var waited = 0
        while coordinator.state != .idle, waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
    }

    // ORA-SM-003: two presses before the async start has run are absorbed by the `starting` reentrancy
    // guard. (Named for the guard it actually exercises — at this point `state` is still `.idle`, so
    // the debounce is not what makes this pass.)
    @MainActor
    func testSecondPressDuringStartupIsIgnored() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        rig.coordinator.toggle()
        await settle()
        XCTAssertEqual(rig.coordinator.state, .recording, "the second press must not have stopped it")
        XCTAssertEqual(rig.audio.startCount, 1)
    }

    // ORA-ACT-004, tested where the debounce is the ONLY guard: once recording, `starting` is false and
    // `state` is `.recording`, so a bounced key would otherwise stop the dictation it just started.
    @MainActor
    func testDebounceSwallowsABouncedKeyWhileRecording() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        await settle()
        XCTAssertEqual(rig.coordinator.state, .recording)

        rig.coordinator.toggle()          // the real stop
        rig.coordinator.toggle()          // bounce, inside 30 ms ⇒ must be swallowed
        await waitUntilIdle(rig.coordinator)

        XCTAssertEqual(rig.audio.stopCount, 1, "a bounced key must not stop and then restart")
        XCTAssertEqual(rig.audio.startCount, 1)
    }

    // ORA-SM-004: capture that fails to start leaves the session IDLE with a legible reason — no
    // indicator over a dictation that isn't happening.
    @MainActor
    func testFailedCaptureStartStaysIdleAndReportsWhy() async throws {
        let rig = try await makeRig()
        rig.audio.throwOnStart = AudioCapture.CaptureError.noInputDevice
        rig.coordinator.toggle()
        await settle()

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertNotNil(rig.coordinator.recentError)
        XCTAssertEqual(rig.feedback.cues, [.error], "a failed start must not play the start cue alone")
    }

    // ORA-SM-012: Escape discards everything — no insertion, and NO recovery entry.
    @MainActor
    func testCancelLeavesNoRecoveryEntryAndInsertsNothing() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        await settle()
        XCTAssertEqual(rig.coordinator.state, .recording)

        rig.coordinator.cancel()
        await settle()

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertTrue(rig.recovery.entries.isEmpty, "a cancelled session must leave no recoverable text")
        XCTAssertTrue(rig.inserter.insertedTexts.isEmpty)
        XCTAssertEqual(rig.audio.stopCount, 1, "capture must be released on cancel")
    }

    // ORA-CAP-022: a late/stale capture failure that arrives once we've left `.recording` must NOT
    // abort — during finalizing/inserting the audio is already stopped and the text is in flight, so
    // aborting there would divert a perfectly good transcript to the recovery menu.
    @MainActor
    func testUnrecoverableFailureIsIgnoredOutsideRecording() async throws {
        let rig = try await makeRig()
        XCTAssertEqual(rig.coordinator.state, .idle)

        rig.audio.onUnrecoverableFailure?("Lost the microphone.")
        await settle()

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertNil(rig.coordinator.lastError, "an abort outside .recording must be a no-op")
        XCTAssertTrue(rig.recovery.entries.isEmpty)
    }

    // ORA-CAP-003 / E6: capture dying mid-dictation moves to another microphone and keeps the SAME
    // session going — confirmed text lives on the coordinator precisely so this is survivable.
    @MainActor
    func testCaptureFailureFailsOverAndKeepsRecording() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        await settle()
        XCTAssertEqual(rig.coordinator.state, .recording)
        XCTAssertEqual(rig.audio.currentDeviceUID, "mic-a")

        rig.audio.onUnrecoverableFailure?("Lost the microphone.")
        await settle()

        XCTAssertEqual(rig.coordinator.state, .recording, "a recoverable mic change must not end the dictation")
        XCTAssertEqual(rig.audio.startCount, 2, "capture must have been restarted")
        // SPEC E6 says the best REMAINING input: the device that just died must be excluded, or every
        // attempt is spent re-opening it (a mic that stops delivering still enumerates as usable).
        XCTAssertEqual(rig.audio.excludedOnLastStart, ["mic-a"])
        XCTAssertEqual(rig.audio.currentDeviceUID, "mic-b", "failover must land on a DIFFERENT device")
        // Failover is meant to be seamless: a terminal-style banner mid-session reads as "it stopped".
        XCTAssertNil(rig.coordinator.notice, "a working failover must not look like the dictation ended")
    }

    // A device that keeps failing can't spin in failover forever.
    @MainActor
    func testFailoverIsBounded() async throws {
        let rig = try await makeRig()
        rig.audio.availableUIDs = ["mic-a", "mic-b", "mic-c", "mic-d", "mic-e"]
        rig.coordinator.toggle()
        await settle()

        for _ in 0..<6 { rig.audio.onUnrecoverableFailure?("Lost the microphone."); await settle(60) }
        await waitUntilIdle(rig.coordinator)

        XCTAssertEqual(rig.coordinator.state, .idle, "repeated failures must terminate, not loop")
        XCTAssertLessThanOrEqual(rig.audio.startCount, 3, "at most the initial start plus 2 failovers")
    }

    // With NO microphone left to fail over to, the dictation ends properly — finalize and INSERT the
    // text into the still-focused target — rather than dumping it into the recovery menu. Seeds real
    // transcript text, without which `insert` bails at its empty-text guard and this never runs.
    @MainActor
    func testCaptureLossWithNoFallbackStillInsertsIntoTheFocusedTarget() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        await settle()
        XCTAssertEqual(rig.coordinator.state, .recording)
        rig.coordinator.speechDidConfirm("hello world")

        rig.audio.availableUIDs = ["mic-a"]           // nothing left once mic-a is excluded
        rig.audio.onUnrecoverableFailure?("Lost the microphone.")
        await waitUntilIdle(rig.coordinator)

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(rig.inserter.insertedTexts, ["hello world"],
                       "text must be offered to the focused target, not parked in the menu")
        XCTAssertEqual(rig.recovery.entries.first?.reason, .inserted,
                       "a placed result is filed as inserted, NOT as .noTarget")
        XCTAssertNotNil(rig.coordinator.recentError)
        XCTAssertNotNil(rig.coordinator.notice, "the mic loss must reach the user even though text landed")
    }

    // The success cue means INSERTED and nothing else — the positive half of the contract.
    @MainActor
    func testSuccessfulInsertPlaysTheCompletionCue() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        await settle()
        rig.coordinator.speechDidConfirm("hello world")
        rig.coordinator.toggle()                       // stop → finalize → insert
        await waitUntilIdle(rig.coordinator)

        // The coordinator hands over text WITHOUT a forced capital: whether it starts a sentence
        // depends on what precedes the caret, which only `TextInserter` can see (SentenceContext).
        XCTAssertEqual(rig.inserter.insertedTexts, ["hello world"])
        XCTAssertEqual(rig.feedback.cues, [.start, .stop])
        XCTAssertEqual(rig.recovery.entries.first?.reason, .inserted)
        // Recovery text stands alone, so it IS capitalized.
        XCTAssertEqual(rig.recovery.entries.first?.text, "Hello world")
        XCTAssertNil(rig.coordinator.notice, "a clean insert needs no explanation")
    }

    // ORA-SM-003: while finalizing/inserting, the hotkey is ignored rather than starting a second
    // dictation on top of the one being placed.
    @MainActor
    func testHotkeyIsIgnoredWhileNotReady() async throws {
        let rig = try await makeRig()
        rig.permissions.mic = false
        await rig.coordinator.refreshReadiness()

        rig.coordinator.toggle()
        await settle()

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(rig.audio.startCount, 0)
        XCTAssertEqual(rig.feedback.cues, [.error])
    }

    // E2: with Accessibility missing the dictation still RUNS and the text is preserved — but the
    // outcome must be distinguishable from success. Regression guard for "every dictation in the
    // supported degraded mode sounded exactly like a successful insert."
    @MainActor
    func testDeferredToRecoveryNeverPlaysTheSuccessCue() async throws {
        let rig = try await makeRig()
        rig.permissions.accessibility = false
        rig.inserter.outcome = .deferredToRecovery(.accessibilityMissing)

        rig.coordinator.toggle()
        await settle()
        rig.coordinator.speechDidConfirm("hello world")   // without text, insert() never runs at all
        rig.coordinator.toggle()                          // stop → finalize → insert
        await waitUntilIdle(rig.coordinator)

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(rig.inserter.insertedTexts, ["hello world"], "the inserter must actually be consulted")
        XCTAssertFalse(rig.feedback.cues.contains(.stop),
                       "the completion cue must mean INSERTED and nothing else")
        XCTAssertTrue(rig.feedback.cues.contains(.error))
        XCTAssertEqual(rig.recovery.entries.first?.reason, .accessibilityMissing)
        XCTAssertNotNil(rig.coordinator.notice)
    }

    // A dictation that produced nothing says so, instead of collapsing exactly like a success.
    @MainActor
    func testEmptyResultIsAnnouncedRatherThanSilent() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        await settle()
        rig.coordinator.toggle()                          // stop with no transcript at all
        await waitUntilIdle(rig.coordinator)

        XCTAssertTrue(rig.inserter.insertedTexts.isEmpty)
        XCTAssertFalse(rig.feedback.cues.contains(.stop))
        XCTAssertEqual(rig.coordinator.notice, "Didn’t catch anything")
    }

    // The capture watchdog only fires while `.recording` — the exact gating ORA-CAP-022 depends on.
    @MainActor
    func testWatchdogDoesNotFireWhileIdle() async throws {
        let rig = try await makeRig()
        rig.audio.stallSeconds = 60       // would be well past the stall limit if it were running
        await settle(300)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertNil(rig.coordinator.lastError)
    }

    // A stalled capture during recording is caught — and the watchdog's FIRST response is failover,
    // not termination.
    @MainActor
    func testWatchdogStallTriggersFailover() async throws {
        let rig = try await makeRig()
        rig.coordinator.toggle()
        await settle()
        XCTAssertEqual(rig.coordinator.state, .recording)

        rig.audio.stallSeconds = 5        // past the 2.5 s steady-state limit
        await settle(400)                 // a few 100 ms ticks

        XCTAssertEqual(rig.audio.startCount, 2, "a stall must first try another microphone")
        XCTAssertEqual(rig.coordinator.state, .recording)
    }

    // …and terminates once there is nowhere left to go.
    @MainActor
    func testWatchdogTerminatesWhenNoDeviceRemains() async throws {
        let rig = try await makeRig()
        rig.audio.availableUIDs = ["mic-a"]
        rig.coordinator.toggle()
        await settle()

        rig.audio.stallSeconds = 5
        await waitUntilIdle(rig.coordinator)

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertNotNil(rig.coordinator.recentError)
    }

    // A device that has not produced its FIRST buffer gets a generous budget: Bluetooth/Continuity
    // mics routinely take 1-3 s to wake up, and the steady-state limit would kill one that was about
    // to work (then re-open the same slow device on failover).
    @MainActor
    func testSlowStartingDeviceIsNotKilledByTheSteadyStateLimit() async throws {
        let rig = try await makeRig()
        rig.audio.hasDeliveredAudio = false      // still waking up
        rig.coordinator.toggle()
        await settle()

        rig.audio.stallSeconds = 4               // past 2.5 s, well inside the startup grace
        await settle(500)

        XCTAssertEqual(rig.coordinator.state, .recording, "a mic that is still waking up must be given time")
        XCTAssertEqual(rig.audio.startCount, 1, "no failover should have been attempted")
    }
}

/// `resolveText` decides what a finished session actually places. Pure, so the duplication hazard it
/// exists to prevent can be pinned exactly.
final class ResolveTextTests: XCTestCase {

    /// The bug this guards: the tail used to be snapshotted BEFORE `drainConfirmed`, so a late final
    /// arriving during the drain was appended to `confirmed` *and* joined again from the stale
    /// snapshot — duplicating those words into the user's document. Reading the tail after the drain
    /// means an absorbed tail is simply empty.
    @MainActor
    func testAbsorbedTailIsNotAppendedTwice() {
        // Post-drain reality when the engine confirmed the tail: volatilePreview was cleared.
        XCTAssertEqual(SessionCoordinator.resolveText(confirmed: "hello world", tail: "", finished: false),
                       "hello world")
    }

    /// A timeout that left a genuinely unconfirmed tail still contributes it (ORA-ASR-003).
    @MainActor
    func testUnconfirmedTailIsAppendedOnTimeout() {
        XCTAssertEqual(SessionCoordinator.resolveText(confirmed: "hello", tail: "world", finished: false),
                       "hello world")
        // No double space when the boundary already has one.
        XCTAssertEqual(SessionCoordinator.resolveText(confirmed: "hello ", tail: "world", finished: false),
                       "hello world")
    }

    /// A clean finalize makes `confirmed` authoritative — the tail must NOT be appended, or every
    /// normal dictation would duplicate its last words.
    @MainActor
    func testCleanFinalizeIgnoresAStaleTail() {
        XCTAssertEqual(SessionCoordinator.resolveText(confirmed: "hello world", tail: "world", finished: true),
                       "hello world")
    }

    /// …except when nothing was confirmed at all, where the tail is the only text there is.
    @MainActor
    func testCleanFinalizeFallsBackToTheTailWhenNothingConfirmed() {
        XCTAssertEqual(SessionCoordinator.resolveText(confirmed: "", tail: "hello", finished: true), "hello")
        XCTAssertEqual(SessionCoordinator.resolveText(confirmed: "", tail: "", finished: true), "")
    }
}

/// `lastError` is an EVENT, not a standing condition: it must not outlive its truth and hide a live,
/// actionable readiness problem in the menu-bar tooltip.
final class ErrorStalenessTests: XCTestCase {

    @MainActor
    private func makeCoordinator(now: @escaping @MainActor () -> Date)
        async throws -> (SessionCoordinator, StubAudio) {
        let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
        let status = await engine.modelStatus()
        try XCTSkipUnless(status == .installed, "en-US model not installed on this host")
        try await engine.warmUp()
        let audio = StubAudio()
        let coordinator = SessionCoordinator(audio: audio, engine: engine, inserter: StubInserter(),
                                             recovery: RecoveryBuffer(), permissions: FakePermissions(),
                                             feedback: SpyFeedback(), now: now)
        return (coordinator, audio)
    }

    /// The actual staleness rule: past the relevance window the error stops being *surfaced*, while
    /// `lastError` itself is retained for logs/diagnostics.
    @MainActor
    func testErrorStopsBeingSurfacedOnceStale() async throws {
        var clock = Date(timeIntervalSince1970: 10_000)
        let (coordinator, audio) = try await makeCoordinator(now: { clock })

        audio.throwOnStart = AudioCapture.CaptureError.noInputDevice
        coordinator.toggle()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(coordinator.recentError, "a fresh failure must be surfaced")

        clock = clock.addingTimeInterval(119)
        XCTAssertNotNil(coordinator.recentError, "still inside the relevance window")

        clock = clock.addingTimeInterval(2)          // now 121 s old
        XCTAssertNil(coordinator.recentError, "a stale error must stop masking live readiness")
        XCTAssertNotNil(coordinator.lastError, "the reason itself is retained, only its surfacing expires")
    }

    /// `cancel()` clears the error on its own — provoked mid-session so no earlier `clearError()` can
    /// be what makes this pass.
    @MainActor
    func testCancelClearsTheError() async throws {
        let (coordinator, _) = try await makeCoordinator(now: { Date() })
        coordinator.toggle()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(coordinator.state, .recording)

        coordinator.reportVocabularyUnavailable()    // sets an error WITHOUT ending the session
        XCTAssertNotNil(coordinator.recentError)

        coordinator.cancel()
        XCTAssertNil(coordinator.recentError, "cancel must clear the error itself")
        XCTAssertNil(coordinator.lastError)
    }

    /// A successful start clears whatever failed before it.
    @MainActor
    func testSuccessfulStartClearsAPriorFailure() async throws {
        let (coordinator, audio) = try await makeCoordinator(now: { Date() })

        audio.throwOnStart = AudioCapture.CaptureError.noInputDevice
        coordinator.toggle()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(coordinator.recentError)

        audio.throwOnStart = nil
        try? await Task.sleep(for: .milliseconds(50))   // clear the 30 ms debounce
        coordinator.toggle()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertNil(coordinator.recentError, "a successful start must clear the previous failure")
    }
}

/// The menu-bar tooltip must prefer a STANDING readiness problem over an error event, so a stale
/// "Lost the microphone" can't hide a live "grant Microphone, Accessibility".
final class StatusTooltipPrecedenceTests: XCTestCase {
    @MainActor
    func testReadinessOutranksAnErrorAndStaleErrorsAreNotShown() async throws {
        let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
        let status = await engine.modelStatus()
        try XCTSkipUnless(status == .installed, "en-US model not installed on this host")
        try await engine.warmUp()

        var clock = Date(timeIntervalSince1970: 10_000)
        let audio = StubAudio()
        let permissions = FakePermissions()
        let coordinator = SessionCoordinator(audio: audio, engine: engine, inserter: StubInserter(),
                                             recovery: RecoveryBuffer(), permissions: permissions,
                                             feedback: SpyFeedback(), now: { clock })
        let item = StatusItemController(coordinator: coordinator)

        // A fresh error while everything else is fine ⇒ the error is the useful thing to say.
        audio.throwOnStart = AudioCapture.CaptureError.noInputDevice
        coordinator.toggle()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(item.tooltipForTesting.contains("microphone"), "a fresh error should be surfaced")

        // A missing permission is a STANDING condition and must win over the error event.
        permissions.mic = false
        await coordinator.refreshReadiness()
        XCTAssertTrue(item.tooltipForTesting.contains("grant"),
                      "an actionable readiness gap must not be hidden by an error")

        // …and once the error is stale it must not reappear even when readiness recovers.
        permissions.mic = true
        await coordinator.refreshReadiness()
        clock = clock.addingTimeInterval(200)
        XCTAssertEqual(item.tooltipForTesting, "Orator — ready")
    }
}
