import AppKit
import Speech
import XCTest
@testable import OratorKit

/// The Settings meter's hold-or-release rule (ORA-CAP-010 / ORA-CAP-026), driven through every
/// ordering that could strand the microphone open. The fix for "Orator keeps the orange indicator lit"
/// was reasoned from code and never reproduced, so these orderings are the evidence it holds: each row
/// replays a sequence of AppKit and Core Audio events against fakes and asserts how many times the
/// microphone was opened and whether it is open at the end.
@MainActor
final class MicLevelMonitorTests: XCTestCase {

    // MARK: Fakes

    /// Counts opens and releases; `isOpen` is what the system's in-use indicator would show.
    @MainActor final class FakeCapture: MeteringCapture {
        var currentLevel: Float = 0
        var isClipping = false
        var startError: Error?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var isOpen = false

        func startMetering() throws -> AsyncStream<AnalyzerInput> {
            if let startError { throw startError }
            startCount += 1
            isOpen = true
            return AsyncStream { $0.finish() }
        }

        func stop() {
            stopCount += 1
            isOpen = false
        }
    }

    /// Stands in for the Core Audio listeners. `fire` is a live callback; `fireStale` replays the last
    /// handler even after `end`, modelling a callback already enqueued on the main queue when the
    /// listener was removed.
    @MainActor final class FakeDeviceChanges: DeviceChangeSource {
        private var handler: (@MainActor () -> Void)?
        private var lastHandler: (@MainActor () -> Void)?
        var isListening: Bool { handler != nil }

        func begin(_ onChange: @escaping @MainActor () -> Void) {
            guard handler == nil else { return }
            handler = onChange
            lastHandler = onChange
        }

        func end() { handler = nil }

        func fire() { handler?() }
        func fireStale() { lastHandler?() }
    }

    struct Boom: Error {}

    /// One monitor wired to fakes, plus the knobs a test turns.
    @MainActor final class Rig {
        let capture = FakeCapture()
        let devices = FakeDeviceChanges()
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        var uid: String? = "A"
        var authorized = true
        var activeAtStart = true
        lazy var monitor = MicLevelMonitor(
            capture: capture, deviceChanges: devices,
            resolve: { [unowned self] in MeterChoice(name: uid.map { "Mic \($0)" }, uid: uid, substituted: false) },
            isAuthorized: { [unowned self] in authorized },
            isAppActive: { [unowned self] in activeAtStart },
            appCenter: appCenter, workspaceCenter: workspaceCenter,
            restartDelay: .milliseconds(5))
    }

    // MARK: The table

    enum Step {
        case start, stop
        case resign, activate, sleep, wake
        /// The resolved device becomes `uid`, then Core Audio reports a change.
        case deviceChange(String?)
        /// A device-change callback that was already in flight when the listener was removed.
        case staleDeviceChange
        /// The Settings picker's own `restart()` on a selection change.
        case selectionChange(String?)
        /// Long enough for any debounced restart to have landed.
        case settle
    }

    private func run(_ steps: [Step], on rig: Rig) async throws {
        for step in steps {
            switch step {
            case .start: rig.monitor.start()
            case .stop: rig.monitor.stop()
            case .resign: rig.appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
            case .activate: rig.appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            case .sleep: rig.workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            case .wake: rig.workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            case .deviceChange(let uid): rig.uid = uid; rig.devices.fire()
            case .staleDeviceChange: rig.devices.fireStale()
            case .selectionChange(let uid): rig.uid = uid; rig.monitor.restart()
            case .settle: try await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    struct Row {
        let name: String
        var activeAtStart = true
        var initialUID: String? = "A"
        let steps: [Step]
        /// Whether the microphone is held at the end — the orange indicator.
        let open: Bool
        let opens: Int
        var releases: Int?
    }

    private let rows: [Row] = [
        Row(name: "Settings open, app active, screens awake holds the mic",
            steps: [.start], open: true, opens: 1),
        Row(name: "start is idempotent",
            steps: [.start, .start], open: true, opens: 1),
        Row(name: "Opening Settings while inactive waits for activation",
            activeAtStart: false, steps: [.start], open: false, opens: 0),
        Row(name: "…and activation then acquires it",
            activeAtStart: false, steps: [.start, .activate], open: true, opens: 1),
        Row(name: "Closing Settings releases",
            steps: [.start, .stop], open: false, opens: 1),
        Row(name: "Reopening Settings re-acquires",
            steps: [.start, .stop, .start], open: true, opens: 2),
        Row(name: "Resigning active releases",
            steps: [.start, .resign], open: false, opens: 1),
        Row(name: "A device change after resigning leaves the mic released",
            steps: [.start, .resign, .deviceChange("B"), .settle], open: false, opens: 1),
        Row(name: "A device-change callback already in flight at resign still leaves it released",
            steps: [.start, .resign, .staleDeviceChange, .settle], open: false, opens: 1),
        Row(name: "A selection change while inactive leaves it released",
            steps: [.start, .resign, .selectionChange("B")], open: false, opens: 1),
        Row(name: "stop() with a debounced restart pending never reopens",
            steps: [.start, .deviceChange("B"), .stop, .settle], open: false, opens: 1),
        Row(name: "A stale callback after stop() never reopens",
            steps: [.start, .stop, .staleDeviceChange, .settle], open: false, opens: 1),
        Row(name: "A screen sleep releases",
            steps: [.start, .sleep], open: false, opens: 1),
        Row(name: "Screen sleep → activation stays released until the screens wake",
            steps: [.start, .sleep, .resign, .activate], open: false, opens: 1),
        Row(name: "…and the wake re-acquires",
            steps: [.start, .sleep, .resign, .activate, .wake], open: true, opens: 2),
        Row(name: "Lock screen: the display waking behind the lock stays released",
            steps: [.start, .resign, .sleep, .wake], open: false, opens: 1),
        Row(name: "…until the app is active again",
            steps: [.start, .resign, .sleep, .wake, .activate], open: true, opens: 2),
        Row(name: "A device change while the screens sleep leaves it released",
            steps: [.start, .sleep, .deviceChange("B"), .settle], open: false, opens: 1),
        Row(name: "Lifecycle and device events after close are ignored",
            steps: [.start, .stop, .activate, .wake, .deviceChange("B"), .settle], open: false, opens: 1),
        Row(name: "An unchanged device is not re-opened (ORA-CAP-008)",
            steps: [.start, .deviceChange("A"), .deviceChange("A"), .settle], open: true, opens: 1, releases: 0),
        Row(name: "A burst of changes to a new device restarts exactly once",
            steps: [.start, .deviceChange("B"), .deviceChange("B"), .deviceChange("B"), .settle],
            open: true, opens: 2, releases: 1),
        Row(name: "A device appearing where there was none brings the meter to life",
            initialUID: nil, steps: [.start, .deviceChange("A"), .settle], open: true, opens: 1),
        Row(name: "The device vanishing releases",
            steps: [.start, .deviceChange(nil), .settle], open: false, opens: 1),
    ]

    func testHoldOrReleaseTable() async throws {
        for row in rows {
            let rig = Rig()
            rig.activeAtStart = row.activeAtStart
            rig.uid = row.initialUID
            try await run(row.steps, on: rig)
            XCTAssertEqual(rig.capture.isOpen, row.open, "open — \(row.name)")
            XCTAssertEqual(rig.capture.startCount, row.opens, "opens — \(row.name)")
            if let releases = row.releases {
                XCTAssertEqual(rig.capture.stopCount, releases, "releases — \(row.name)")
            }
            // Once the meter has decided not to hold the mic, nothing may still be listening for a
            // device change that could re-open it. (Rows that end open with a device are listening.)
            if !row.open, rig.uid != nil {
                XCTAssertFalse(rig.devices.isListening, "still listening — \(row.name)")
            }
            rig.monitor.stop()
            XCTAssertFalse(rig.capture.isOpen, "close released — \(row.name)")
        }
    }

    // MARK: Rules the table can't state

    /// Denied TCC access delivers silence rather than throwing, so the meter must never even try to
    /// open the device — and must say why.
    func testPermissionDeniedNeverOpensTheDevice() async throws {
        let rig = Rig()
        rig.authorized = false
        try await run([.start, .deviceChange("B"), .settle], on: rig)
        XCTAssertEqual(rig.capture.startCount, 0)
        XCTAssertTrue(rig.monitor.permissionDenied)
        rig.monitor.stop()
    }

    /// The release is unconditional (ORA-CAP-026): even when the monitor never believed it was running
    /// — here the open threw — closing Settings still reaches the capture's own `stop`, so a desync
    /// between the two flags can't strand the device.
    func testReleaseReachesTheCaptureEvenWhenTheOpenFailed() {
        let rig = Rig()
        rig.capture.startError = Boom()
        rig.monitor.start()
        XCTAssertEqual(rig.monitor.openFailure, "Mic A")
        let before = rig.capture.stopCount
        rig.monitor.stop()
        XCTAssertGreaterThan(rig.capture.stopCount, before)
    }

    /// Settings closed while the screens were asleep, the screens woke while it was closed, then it
    /// reopened. The user is plainly in front of the machine, so the meter should run — even though
    /// `stop()` removed the lifecycle observers and the wake itself went unheard.
    func testReopeningAfterAWakeMissedWhileClosedMetersAgain() async throws {
        let rig = Rig()
        try await run([.start, .sleep, .stop, .wake, .start], on: rig)
        XCTAssertTrue(rig.capture.isOpen)
        rig.monitor.stop()
    }
}
