import XCTest
@preconcurrency import AVFoundation
import Speech
@testable import OratorKit

@MainActor private final class E2EInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    func insert(_ text: String, into target: TargetContext,
                accessibilityGranted: Bool) async -> InsertionOutcome {
        insertedTexts.append(text); return .inserted
    }
}
@MainActor private final class GrantedPermissions: PermissionsManager {
    override var microphoneGranted: Bool { true }
    override var accessibilityGranted: Bool { true }
}
private final class QuietFeedback: SoundFeedback, @unchecked Sendable {
    override func playStart() {} ; override func playStop() {} ; override func playError() {}
}

/// End-to-end through the REAL `SessionCoordinator`: hotkey → capture → token → bridge → analyzer →
/// drain → insert. The engine-only E2E test skips all the coordinator wiring (session token, bridge
/// task, resolveText), which is exactly where a "records fine but no text" fault would live.
final class CoordinatorE2ETests: XCTestCase {
    @MainActor
    func testFullCoordinatorPathProducesAndInsertsText() async throws {
        let phrase = "the quick brown fox jumps over the lazy dog"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orator-coord.aiff")
        try? FileManager.default.removeItem(at: url)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, phrase]
        try say.run(); say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "`say` unavailable")

        let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
        let status = await engine.modelStatus()
        try XCTSkipUnless(status == .installed, "en-US model not installed")
        try await engine.warmUp()

        let inserter = E2EInserter()
        let coordinator = SessionCoordinator(
            audio: FileAudioCapture(url: url, realtime: true), engine: engine, inserter: inserter,
            recovery: RecoveryBuffer(), permissions: GrantedPermissions(), feedback: QuietFeedback())

        coordinator.toggle()                       // start
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(coordinator.state, .recording)
        try await Task.sleep(for: .seconds(3))     // let the file play through
        coordinator.toggle()                       // stop → finalize → insert

        var waited = 0
        while coordinator.state != .idle, waited < 10_000 {
            try await Task.sleep(for: .milliseconds(50)); waited += 50
        }
        let text = (inserter.insertedTexts.first ?? "").lowercased()
        print("PROBE coordinator inserted: '\(text)'")
        XCTAssertFalse(text.isEmpty, "the coordinator path produced NO text end-to-end")
        XCTAssertTrue(["fox", "quick", "brown", "dog"].contains { text.contains($0) },
                      "unexpected transcript: '\(text)'")
    }
}
