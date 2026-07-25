import XCTest
@testable import OratorKit

/// The Settings mic readout carries two NAMED requirements that had no test and no way to get one
/// while they lived inside a SwiftUI `View` body: ORA-CAP-005 (a fallen-back pin must read as
/// "Automatic (name)", never as the pinned device) and ORA-CAP-011 (identical device names are
/// disambiguated by a UID suffix). This is the decision table for both.
final class MicStatusTests: XCTestCase {

    private func text(permissionDenied: Bool = false, openFailure: String? = nil,
                      liveName: String? = nil, resolvedName: String? = nil,
                      selection: MicSelection = .automatic, substituted: Bool = false,
                      clipping: Bool = false) -> String {
        MicStatus.text(permissionDenied: permissionDenied, openFailure: openFailure,
                       liveName: liveName, resolvedName: resolvedName,
                       selection: selection, substituted: substituted, clipping: clipping)
    }

    /// Clipping outranks the normal readout: the mic IS working, but it's being driven into
    /// distortion, which costs recognition accuracy in a way no downstream setting can undo.
    func testClippingOutranksTheNormalReadoutButNotPermission() {
        XCTAssertEqual(text(liveName: "Yeti X", clipping: true),
                       "Input is too loud — lower the microphone gain")
        // …but a mic we cannot open at all is still the more important thing to say.
        XCTAssertEqual(text(permissionDenied: true, liveName: "Yeti X", clipping: true),
                       "Microphone access is off — enable it in System Settings")
        // Not clipping ⇒ unchanged behaviour.
        XCTAssertEqual(text(liveName: "Yeti X", clipping: false), "Automatic (Yeti X)")
    }

    // MARK: Status line

    func testSelectionModesReadAsTheEffectiveMode() {
        XCTAssertEqual(text(liveName: "Studio Mic", selection: .automatic), "Automatic (Studio Mic)")
        XCTAssertEqual(text(liveName: "MacBook Air Microphone", selection: .builtIn),
                       "Built-in (MacBook Air Microphone)")
    }

    // ORA-CAP-005: the whole point of `substituted`.
    func testPinnedDeviceShowsItsOwnNameOnlyWhenActuallyInUse() {
        XCTAssertEqual(text(liveName: "Work USB Camera", selection: .device(uid: "USB:1"), substituted: false),
                       "Work USB Camera")
        XCTAssertEqual(text(liveName: "MacBook Air Microphone", selection: .device(uid: "USB:1"), substituted: true),
                       "Automatic (MacBook Air Microphone)",
                       "a fallen-back pin must NOT imply the pinned device is in use")
    }

    func testLiveNameWinsOverMeterNameSoThePickerAndStatusAgree() {
        XCTAssertEqual(text(liveName: "Core Audio Name", resolvedName: "AVF Name"),
                       "Automatic (Core Audio Name)")
        XCTAssertEqual(text(liveName: nil, resolvedName: "AVF Name"), "Automatic (AVF Name)")
    }

    func testNoUsableDeviceIsStatedPlainly() {
        XCTAssertEqual(text(liveName: nil, resolvedName: nil), "No microphone available")
    }

    /// Permission outranks everything: while the mic can't be opened at all, naming a resolved device
    /// or an open failure would send the user chasing the wrong fix.
    func testPermissionDeniedOutranksEveryOtherState() {
        let denied = text(permissionDenied: true, openFailure: "Studio Mic",
                          liveName: "Studio Mic", selection: .builtIn, substituted: true)
        XCTAssertEqual(denied, "Microphone access is off — enable it in System Settings")
    }

    /// "Exists but busy" must not be reported as "missing" — different device, different fix.
    func testOpenFailureIsDistinctFromNoDevice() {
        XCTAssertEqual(text(openFailure: "Studio Mic", liveName: "Studio Mic"),
                       "Studio Mic unavailable — may be in use")
    }

    // MARK: Picker row labels (ORA-CAP-011)

    private func device(_ uid: String, _ name: String) -> CoreAudioSupport.InputDevice {
        CoreAudioSupport.InputDevice(uid: uid, name: name)
    }

    func testCollidingNamesGetAUIDSuffixAndUniqueOnesDoNot() {
        let a = device("AAAA-1111", "USB Camera")
        let b = device("BBBB-2222", "USB Camera")
        let solo = device("CCCC-3333", "Studio Mic")
        let all = [a, b, solo]

        XCTAssertEqual(MicStatus.rowLabel(for: a, among: all, defaultUID: nil), "USB Camera (1111)")
        XCTAssertEqual(MicStatus.rowLabel(for: b, among: all, defaultUID: nil), "USB Camera (2222)")
        XCTAssertEqual(MicStatus.rowLabel(for: solo, among: all, defaultUID: nil), "Studio Mic",
                       "a unique name must NOT be cluttered with a UID suffix")
    }

    func testSystemDefaultIsAnnotated() {
        let solo = device("CCCC-3333", "Studio Mic")
        XCTAssertEqual(MicStatus.rowLabel(for: solo, among: [solo], defaultUID: "CCCC-3333"),
                       "Studio Mic (default)")
    }

    /// Both annotations can apply to the same row, in a stable order.
    func testCollidingDefaultGetsBothAnnotations() {
        let a = device("AAAA-1111", "USB Camera")
        let b = device("BBBB-2222", "USB Camera")
        XCTAssertEqual(MicStatus.rowLabel(for: a, among: [a, b], defaultUID: "AAAA-1111"),
                       "USB Camera (1111) (default)")
    }
}
