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
            audio: FileAudioCapture(url: url, realtime: true), engine: engine, inserter: inserter,
            recovery: RecoveryBuffer(), permissions: FakePermissions(), feedback: SpyFeedback())

        coordinator.toggle()                       // start
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(coordinator.state, .recording)
        try await Task.sleep(for: .seconds(3))     // let the file play through
        coordinator.toggle()                       // stop → finalize → insert

        await waitUntilIdle(coordinator, timeoutMs: 10_000)
        let text = (inserter.insertedTexts.first ?? "").lowercased()
        print("PROBE coordinator inserted: '\(text)'")
        XCTAssertFalse(text.isEmpty, "the coordinator path produced NO text end-to-end")
        XCTAssertTrue(["fox", "quick", "brown", "dog"].contains { text.contains($0) },
                      "unexpected transcript: '\(text)'")
    }
}
