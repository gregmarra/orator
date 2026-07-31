import XCTest
import AppKit
@preconcurrency import AVFoundation
import Carbon.HIToolbox
@testable import OratorKit

/// Automated verification for the requirements that have a testable seam (§15.1 "test").
final class OratorKitTests: XCTestCase {

    // AC-6 / ORA-REC-003: entry gone from memory 5 min after creation, no user interaction.
    @MainActor
    func testRecoveryBufferHardTTL() {
        var fake = Date(timeIntervalSince1970: 1000)
        let buffer = RecoveryBuffer(now: { fake })
        buffer.add("hello world", reason: .inserted)
        XCTAssertEqual(buffer.entries.count, 1)

        fake = fake.addingTimeInterval(4 * 60)        // 4 min — still alive
        buffer.sweep()
        XCTAssertEqual(buffer.entries.count, 1)

        fake = fake.addingTimeInterval(2 * 60)        // now 6 min — expired
        buffer.sweep()
        XCTAssertEqual(buffer.entries.count, 0, "entry MUST expire at the 5-minute hard TTL")
    }

    // ORA-REC-006: bounded to ≤ 10 regardless of TTL.
    @MainActor
    func testRecoveryBufferBounded() {
        let buffer = RecoveryBuffer(now: { Date(timeIntervalSince1970: 0) })
        for i in 0..<25 { buffer.add("entry \(i)", reason: .inserted) }
        XCTAssertLessThanOrEqual(buffer.entries.count, RecoveryBuffer.maxEntries)
    }

    // ORA-SM-012 corollary: empty results never create an entry (a discarded/empty session leaves none).
    @MainActor
    func testEmptyResultLeavesNoEntry() {
        let buffer = RecoveryBuffer(now: { Date(timeIntervalSince1970: 0) })
        buffer.add("", reason: .inserted)
        buffer.add("real text", reason: .inserted)
        XCTAssertEqual(buffer.entries.count, 1)
    }

    /// A private pasteboard for every test in this file. Writing fixtures to `NSPasteboard.general`
    /// clobbers the developer's real clipboard AND leaves a stale value that a later dictation's
    /// deferred restore can paste into their document — observed happening.
    @MainActor
    private func withPrivatePasteboard(_ body: (NSPasteboard) -> Void) {
        let pb = NSPasteboard(name: .init("OratorTests-\(UUID().uuidString)"))
        let previous = Pasteboard.board
        Pasteboard.board = pb
        defer { Pasteboard.board = previous; pb.releaseGlobally() }
        body(pb)
    }

    // ORA-INS-005 / B4: the concealed + string markers live on the SAME pasteboard item.
    @MainActor
    func testConcealedMarkerOnStringItem() {
        withPrivatePasteboard { pb in
        Pasteboard.writeConcealed("secret")
        let items = pb.pasteboardItems ?? []
        XCTAssertEqual(items.count, 1, "one item carries all types")
        let types = Set(items.first?.types.map(\.rawValue) ?? [])
        XCTAssertTrue(types.contains("public.utf8-plain-text"))
        XCTAssertTrue(types.contains(Pasteboard.concealedType.rawValue))
        }
    }

    // ORA-IND-001: glyph derivation across state × readiness.
    func testGlyphDerivation() {
        XCTAssertEqual(IndicatorGlyph.from(state: .idle, readiness: .ready), .ready)
        XCTAssertEqual(IndicatorGlyph.from(state: .recording, readiness: .ready), .recording)
        XCTAssertEqual(IndicatorGlyph.from(state: .finalizing, readiness: .ready), .working)
        XCTAssertEqual(IndicatorGlyph.from(state: .inserting, readiness: .ready), .working)
        // Not-ready dominates regardless of session state (ORA-PERM-003).
        XCTAssertEqual(IndicatorGlyph.from(state: .idle, readiness: .needsPermission([.microphone])), .notReady)
        XCTAssertEqual(IndicatorGlyph.from(state: .recording, readiness: .needsModel(.missing)), .notReady)
        // Degraded hotkey can still dictate (ORA-ACT-006): not a not-ready glyph.
        XCTAssertEqual(IndicatorGlyph.from(state: .idle, readiness: .degradedHotkey), .ready)
    }

    func testReadinessGating() {
        XCTAssertTrue(Readiness.ready.canStartDictation)
        XCTAssertTrue(Readiness.degradedHotkey.canStartDictation)
        // E2: an Accessibility-only gap still allows recording (insertion routes to recovery).
        XCTAssertTrue(Readiness.needsPermission([.accessibility]).canStartDictation)
        // Microphone is record-blocking; model missing is record-blocking.
        XCTAssertFalse(Readiness.needsPermission([.microphone]).canStartDictation)
        XCTAssertFalse(Readiness.needsPermission([.microphone, .accessibility]).canStartDictation)
        XCTAssertFalse(Readiness.needsModel(.missing).canStartDictation)
    }

    // ORA-INS-005 / E13: restore must NOT clobber a newer clipboard.
    @MainActor
    func testPasteboardChangeCountGuard() {
        withPrivatePasteboard { pb in
        pb.clearContents(); pb.setString("original", forType: .string)
        let snapshot = Pasteboard.snapshot()
        let ourCount = Pasteboard.writeConcealed("dictated")
        XCTAssertEqual(pb.string(forType: .string), "dictated")

        // Simulate the user copying something during the deferred-restore window.
        pb.clearContents(); pb.setString("user copied this", forType: .string)

        let restored = Pasteboard.restore(snapshot, ifUnchangedFrom: ourCount)
        XCTAssertFalse(restored, "must not clobber a newer clipboard")
        XCTAssertEqual(pb.string(forType: .string), "user copied this")
        }
    }

    // ORA-INS-005 happy path: restore when unchanged.
    @MainActor
    func testPasteboardRestoreWhenUnchanged() {
        withPrivatePasteboard { pb in
        pb.clearContents(); pb.setString("original", forType: .string)
        let snapshot = Pasteboard.snapshot()
        let ourCount = Pasteboard.writeConcealed("dictated")
        let restored = Pasteboard.restore(snapshot, ifUnchangedFrom: ourCount)
        XCTAssertTrue(restored)
        XCTAssertEqual(pb.string(forType: .string), "original")
        }
    }

    // ORA-CFG-002: settings defaults + round-trip via an isolated suite.
    @MainActor
    func testSettingsDefaultsAndPersistence() {
        let suite = UserDefaults(suiteName: "OratorTests-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        XCTAssertEqual(settings.micSelection, .automatic)     // ORA-CAP-002 default
        XCTAssertEqual(settings.localeIdentifier, "en-US")    // English v1
        XCTAssertTrue(settings.soundEnabled)
        XCTAssertEqual(settings.hotkey, .defaultChord)        // ⌥Space
    }

    // Mic selection persists and migrates the legacy "MicPolicy" key. Round-trips through the compact
    // storage form. ORA-CAP-002 allows exactly two states — a retired `device:<uid>` pin written by an
    // older build MUST read back as `.automatic` rather than stranding that install on a dead pin.
    @MainActor
    func testMicSelectionPersistenceAndMigration() {
        for sel: MicSelection in [.automatic, .builtIn] {
            XCTAssertEqual(MicSelection(storageValue: sel.storageValue), sel)
        }
        let suite = UserDefaults(suiteName: "OratorTests-\(UUID().uuidString)")!
        let settings = Settings(defaults: suite)
        settings.micSelection = .builtIn
        XCTAssertEqual(Settings(defaults: suite).micSelection, .builtIn)

        // Legacy MicPolicy values migrate: followDefault → automatic, builtIn → builtIn.
        let legacy = UserDefaults(suiteName: "OratorTests-\(UUID().uuidString)")!
        legacy.set("followDefault", forKey: "MicPolicy")
        XCTAssertEqual(Settings(defaults: legacy).micSelection, .automatic)
        legacy.set("builtIn", forKey: "MicPolicy")
        XCTAssertEqual(Settings(defaults: legacy).micSelection, .builtIn)

        // The retired per-device pin.
        let pinned = UserDefaults(suiteName: "OratorTests-\(UUID().uuidString)")!
        pinned.set("device:ABC-USB-Cam:1", forKey: "MicSelection")
        XCTAssertEqual(Settings(defaults: pinned).micSelection, .automatic)
    }

    // ORA-IND-012: panel size is a pure function of notch/pill — independent of preview text length.
    //
    // The text-independence half of this is enforced by the TYPE, not by an assertion:
    // `IndicatorMetrics.size(isNotch:)` takes no text parameter, so there is nothing for a preview
    // string to influence. (This test used to "prove" it by calling that function twice through a
    // helper that discarded its own `text` argument — two identical calls, which could not fail.)
    func testFixedIndicatorSizeIndependentOfText() {
        // Notch panel is taller than the pill: content sits BELOW the opaque notch band
        // (ORA-IND-011), so height = notchBand + contentHeight.
        XCTAssertGreaterThan(IndicatorMetrics.size(isNotch: true).height,
                             IndicatorMetrics.size(isNotch: false).height)
        XCTAssertEqual(IndicatorMetrics.size(isNotch: true, notchBand: 32).height,
                       32 + IndicatorMetrics.contentHeight)
    }

    // ORA-INS-004: the paste key code resolves to the key that types "v" in the current layout —
    // the ANSI-V physical key on a standard ANSI/QWERTY host. Also proves the resolver returns a
    // real hardware key code and never crashes.
    @MainActor
    func testPasteKeyCodeResolvesVKey() {
        let code = TextInserter.pasteKeyCode()
        XCTAssertLessThan(code, 128)                    // a real hardware key code
        XCTAssertEqual(code, CGKeyCode(kVK_ANSI_V))     // ANSI/QWERTY test host
    }

    // Built-in resolver must land on a real Built-in-transport device, not a Continuity/Bluetooth
    // device that merely happens to be first (the first-device-fallthrough bug).
    @MainActor
    func testBuiltInMicResolvesToBuiltInTransport() throws {
        try XCTSkipUnless(CoreAudioSupport.builtInInputUID() != nil, "no built-in input on this host")
        let builtInUID = CoreAudioSupport.builtInInputUID()
        // Built-in mode must resolve to THE built-in (transport-matched UID), not the first arbitrary mic.
        let resolved = AudioCapture.resolveUID(.builtIn, using: .live)
        XCTAssertEqual(resolved.uid, builtInUID,
                       "built-in resolution did not land on the built-in device")
        // The memoized O(1) built-in lookup must agree with the authoritative enumeration.
        XCTAssertEqual(AudioCapture.cachedBuiltInInputUID(), builtInUID)
    }


    // ORA-CAP-012: the pure selection decision, exercised headlessly with a fake DeviceProvider —
    // every fallback/substitution branch without touching hardware.
    @MainActor
    func testResolveUIDDecisionTable() {
        func provider(_ def: String?, _ builtIn: String?, usable: Set<String>, ordered: [String])
            -> AudioCapture.DeviceProvider {
            AudioCapture.DeviceProvider(
                defaultInputUID: { def }, builtInUID: { builtIn },
                isUsable: { usable.contains($0) }, orderedInputUIDs: { ordered })
        }

        // automatic + usable default → as-selected, not substituted
        var r = AudioCapture.resolveUID(.automatic, using: provider("D", "B", usable: ["D", "B"], ordered: ["D", "B"]))
        XCTAssertEqual(r.uid, "D"); XCTAssertFalse(r.substituted)

        // automatic + garbage default → best usable (built-in), substituted
        r = AudioCapture.resolveUID(.automatic, using: provider("D", "B", usable: ["B"], ordered: ["D", "B"]))
        XCTAssertEqual(r.uid, "B"); XCTAssertTrue(r.substituted)

        // builtIn + present and usable → as-selected, not substituted
        r = AudioCapture.resolveUID(.builtIn, using: provider("D", "B", usable: ["D", "B"], ordered: ["D", "B"]))
        XCTAssertEqual(r.uid, "B"); XCTAssertFalse(r.substituted)

        // builtIn + no built-in present → best usable other, substituted
        r = AudioCapture.resolveUID(.builtIn, using: provider("X", nil, usable: ["X"], ordered: ["X"]))
        XCTAssertEqual(r.uid, "X"); XCTAssertTrue(r.substituted)

        // builtIn + built-in present but unusable (garbage channels) → best usable other, substituted
        r = AudioCapture.resolveUID(.builtIn, using: provider("X", "B", usable: ["X"], ordered: ["B", "X"]))
        XCTAssertEqual(r.uid, "X"); XCTAssertTrue(r.substituted)

        // nothing usable → nil uid (caller throws noInputDevice rather than capturing a dead device)
        r = AudioCapture.resolveUID(.automatic, using: provider("D", "B", usable: [], ordered: ["D", "B"]))
        XCTAssertNil(r.uid)
    }

    // ORA-CAP-015: distinct, legible failure copy for the real recording surface.
    func testCaptureErrorMessagesAreDistinct() {
        XCTAssertEqual(AudioCapture.CaptureError.noInputDevice.errorDescription, "No microphone is connected.")
        let opened = AudioCapture.CaptureError.sessionStartFailed("raw").errorDescription
        XCTAssertNotNil(opened)
        XCTAssertNotEqual(opened, AudioCapture.CaptureError.noInputDevice.errorDescription)
    }

    // ORA-ASR-007: the recognizer emits stray leading punctuation for the opening pause. Cases below
    // are verbatim from live dictation traces. `clean` no longer changes case — capitalization now
    // depends on the target field's contents (see SentenceContextTests).
    func testTranscriptCleanerStripsLeadingJunk() {
        XCTAssertEqual(TranscriptCleaner.clean(".. the waveform actually feels responsive."),
                       "the waveform actually feels responsive.")
        XCTAssertEqual(TranscriptCleaner.clean(", you... there are still some of these"),
                       "you... there are still some of these")
        XCTAssertEqual(TranscriptCleaner.clean(",... the speed is feeling pretty good"),
                       "the speed is feeling pretty good")
        XCTAssertEqual(TranscriptCleaner.clean("…  hello world"), "hello world")
        // Already-clean text is untouched (idempotent), and internal punctuation is preserved.
        XCTAssertEqual(TranscriptCleaner.clean("Testing the waveform."), "Testing the waveform.")
        XCTAssertEqual(TranscriptCleaner.clean(""), "")
    }

    // Capitalization applied at a sentence start reproduces the old end-to-end behaviour.
    func testCleanThenCapitalizeMatchesSentenceStartOutput() {
        XCTAssertEqual(TranscriptCleaner.capitalized(TranscriptCleaner.clean(".. the waveform actually feels responsive.")),
                       "The waveform actually feels responsive.")
        XCTAssertEqual(TranscriptCleaner.capitalized(TranscriptCleaner.clean("…  hello world")), "Hello world")
        XCTAssertEqual(TranscriptCleaner.capitalized(""), "")
    }
}

/// Per-session isolation: each dictation gets its own analyzer, transcriber, stream and results task,
/// so nothing can leak or drop across sessions.
final class SessionIsolationTests: XCTestCase {
    /// The SessionToken guard exists so a bridge that outlives its session cannot bleed the previous
    /// dictation's audio into the next transcript. Every other test feeds the token it just received,
    /// so none of them can fail if the guard is deleted — this one feeds a RETIRED token deliberately.
    /// Verified by mutation: deleting the token check makes this fail.
    @MainActor
    func testFeedingARetiredTokenIsDropped() async throws {
        let url = try sayToFile("the silver wolf howls beneath the moon", "orator-token.aiff")
        let engine = try await warmEngine()
        let format = try XCTUnwrap(engine.inputFormat)
        let collector = TranscriptCollector()
        engine.sink = collector

        // Session A, retired without ever being fed.
        let startedA = await engine.beginSession()
        let a = try XCTUnwrap(startedA)
        engine.endSession()

        // Session B is live. Feeding A's token must yield NOTHING into it.
        let startedB = await engine.beginSession()
        let b = try XCTUnwrap(startedB)
        XCTAssertNotEqual(a, b, "each session must get a distinct token")

        // `realtime: true` matters: fed flat out the analyzer produces nothing at all, and the
        // assertion below would then pass for the wrong reason.
        let stale = FileAudioCapture(url: url, realtime: true)
        let staleStream = try stale.start(outputFormat: format)
        for await input in staleStream { engine.feed(input, for: a) }   // retired token
        _ = await engine.finalize(within: .seconds(5))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(collector.confirmed.isEmpty,
                      "audio fed with a retired token leaked into the live session: '\(collector.confirmed)'")
        engine.endSession()
    }
}

/// Reproduces the cross-session bleed the user hit (words from the previous session leaking into
/// the next). Runs alternating utterances back-to-back through the SAME warm analyzer — the app's
/// real lifecycle — asserting each session gets its OWN words (no leak) and is non-empty (no drop).
/// Headless: no mic, no user.
final class CrossSessionTests: XCTestCase {
    @MainActor
    func testBackToBackSessionsDoNotLeakOrDrop() async throws {
        let a = try sayToFile("the silver wolf howls beneath the moon", "orator-sessA.aiff")
        let b = try sayToFile("alpha bravo charlie delta echo", "orator-sessB.aiff")
        let engine = try await warmEngine()

        // `transcribe` IS the coordinator's sequence (start → beginSession → bridge → finalize →
        // endSession); this test's value is running it repeatedly against one warm engine, not owning
        // a private copy of the rig. The copy it replaced had drifted to a 200 ms post-finalize sleep.
        for round in 0..<3 {
            let t1 = try await transcribe(a, through: engine)
            let t2 = try await transcribe(b, through: engine)
            XCTAssertFalse(t1.isEmpty, "round \(round): session A dropped (produced nothing)")
            XCTAssertFalse(t2.isEmpty, "round \(round): session B dropped (produced nothing)")
            // No truncation: the LAST word of each utterance must be present.
            XCTAssertTrue(t1.contains("moon"), "round \(round): session A truncated — got '\(t1)'")
            XCTAssertTrue(t2.contains("echo"), "round \(round): session B truncated — got '\(t2)'")
            // No leak: A's words must not appear in B's transcript and vice-versa.
            XCTAssertFalse(t2.contains("wolf") || t2.contains("moon"),
                           "round \(round): session A leaked into B — got '\(t2)'")
            XCTAssertFalse(t1.contains("bravo") || t1.contains("charlie"),
                           "round \(round): session B leaked into A — got '\(t1)'")
        }
    }
}
