import XCTest
@preconcurrency import AVFoundation
import Speech
@testable import OratorKit

/// End-to-end through the REAL `SessionCoordinator`: hotkey → capture → token → bridge → analyzer →
/// drain → insert. The engine-only E2E test skips all the coordinator wiring (session token, bridge
/// task, resolveText), which is exactly where a "records fine but no text" fault would live.
final class CoordinatorE2ETests: XCTestCase {
    @MainActor
    func testFullCoordinatorPathProducesAndInsertsText() async throws {
        let phrase = "the quick brown fox jumps over the lazy dog"
        let url = try sayToFile(phrase, "orator-coord.aiff")
        let engine = try await warmEngine()
        let inserter = StubInserter()
        let coordinator = SessionCoordinator(
            audio: FileAudioCapture(url: url, realtime: true, holdsOpen: true), engine: engine, inserter: inserter,
            recovery: RecoveryBuffer(), permissions: FakePermissions(), feedback: SpyFeedback())

        coordinator.toggle()                       // start
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(coordinator.state, .recording)
        // Stop ~150 ms after the last word, as a person does — not seconds later, which leaves the
        // recognizer nothing to do at stop and flatters every stop-path timing.
        try await Task.sleep(for: .seconds(try duration(of: url) - 0.4 + 0.15))
        coordinator.toggle()                       // stop → finalize → insert

        await waitUntilIdle(coordinator, timeoutMs: 10_000)
        let text = (inserter.insertedTexts.first ?? "").lowercased()
        print("PROBE coordinator inserted: '\(text)'")
        XCTAssertFalse(text.isEmpty, "the coordinator path produced NO text end-to-end")
        XCTAssertTrue(["fox", "quick", "brown", "dog"].contains { text.contains($0) },
                      "unexpected transcript: '\(text)'")
    }

    /// Latency probe, not a correctness test: how stop→inserted scales with dictation length — the
    /// question "does the recognizer keep up while recording, or is everything left for finalize?".
    /// Opt-in (~45 s of real-time playback): `ORATOR_PERF=1 swift test --filter testStopLatencyByLength`
    /// with the `OratorDebugLog` default set for the xctest tool, reading the ⏱ stages from `log stream`.
    @MainActor
    func testStopLatencyByLength() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORATOR_PERF"] == "1", "set ORATOR_PERF=1")
        let sentence = "the quick brown fox jumps over the lazy dog while the band plays on."
        for repeats in [1, 4, 10] {
            let url = try sayToFile(Array(repeating: sentence, count: repeats).joined(separator: " "),
                                    "orator-perf-\(repeats).aiff")
            let engine = try await warmEngine()
            let inserter = StubInserter()
            let coordinator = SessionCoordinator(
                audio: FileAudioCapture(url: url, realtime: true, holdsOpen: true), engine: engine, inserter: inserter,
                recovery: RecoveryBuffer(), permissions: FakePermissions(), feedback: SpyFeedback())
            let seconds = try duration(of: url)
            coordinator.toggle()
            try await Task.sleep(for: .seconds(seconds + 0.15))
            let stopped = ContinuousClock.now
            coordinator.toggle()
            await waitUntilIdle(coordinator, timeoutMs: 15_000)
            print("PROBE length \(String(format: "%.1f", seconds))s → stop→idle \(String(format: "%.0f", (ContinuousClock.now - stopped).milliseconds)) ms")
            XCTAssertFalse(inserter.insertedTexts.isEmpty)
        }
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
