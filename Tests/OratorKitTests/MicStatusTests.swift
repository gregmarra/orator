import XCTest
@testable import OratorKit

/// Decision table for the Settings mic readout, which had no test and no way to get one while it
/// lived inside a SwiftUI `View` body. The rule that matters is ORA-CAP-025: a selection we could not
/// honour must read as "Automatic (name)" and never imply the selected mode is in force.
final class MicStatusTests: XCTestCase {

    private func text(permissionDenied: Bool = false, openFailure: String? = nil,
                      resolvedName: String? = nil,
                      selection: MicSelection = .automatic, substituted: Bool = false,
                      clipping: Bool = false) -> String {
        MicStatus.text(permissionDenied: permissionDenied, openFailure: openFailure,
                       resolvedName: resolvedName,
                       selection: selection, substituted: substituted, clipping: clipping)
    }

    /// Clipping outranks the normal readout: the mic IS working, but it's being driven into
    /// distortion, which costs recognition accuracy in a way no downstream setting can undo.
    func testClippingOutranksTheNormalReadoutButNotPermission() {
        XCTAssertEqual(text(resolvedName: "Yeti X", clipping: true),
                       "Input is too loud — lower the microphone gain")
        // …but a mic we cannot open at all is still the more important thing to say.
        XCTAssertEqual(text(permissionDenied: true, resolvedName: "Yeti X", clipping: true),
                       "Microphone access is off — enable it in System Settings")
        // Not clipping ⇒ unchanged behaviour.
        XCTAssertEqual(text(resolvedName: "Yeti X", clipping: false), "Automatic (Yeti X)")
    }

    func testSelectionModesReadAsTheEffectiveMode() {
        XCTAssertEqual(text(resolvedName: "Studio Mic", selection: .automatic), "Automatic (Studio Mic)")
        XCTAssertEqual(text(resolvedName: "MacBook Air Microphone", selection: .builtIn),
                       "Built-in (MacBook Air Microphone)")
    }

    /// ORA-CAP-025 — the whole point of `substituted`. Note this now covers `.builtIn`, which it did not:
    /// on a Mac with no built-in mic, "Built-in" selected used to read "Built-in (Some USB Mic)" —
    /// naming a mode that was not in force, the exact claim this rule exists to prevent.
    func testASubstitutedSelectionReadsAsAutomatic() {
        XCTAssertEqual(text(resolvedName: "Some USB Mic", selection: .builtIn, substituted: true),
                       "Automatic (Some USB Mic)",
                       "a substituted Built-in must NOT imply the built-in mic is in use")
        // Automatic that fell back off a garbage system default still reads as Automatic — same words,
        // and correctly so: automatic IS what is in force.
        XCTAssertEqual(text(resolvedName: "Fallback Mic", selection: .automatic, substituted: true),
                       "Automatic (Fallback Mic)")
    }

    func testNoUsableDeviceIsStatedPlainly() {
        XCTAssertEqual(text(resolvedName: nil), "No microphone available")
    }

    /// Permission outranks everything: while the mic can't be opened at all, naming a resolved device
    /// or an open failure would send the user chasing the wrong fix.
    func testPermissionDeniedOutranksEveryOtherState() {
        let denied = text(permissionDenied: true, openFailure: "Studio Mic",
                          resolvedName: "Studio Mic", selection: .builtIn, substituted: true)
        XCTAssertEqual(denied, "Microphone access is off — enable it in System Settings")
    }

    /// "Exists but busy" must not be reported as "missing" — different device, different fix.
    func testOpenFailureIsDistinctFromNoDevice() {
        XCTAssertEqual(text(openFailure: "Studio Mic", resolvedName: "Studio Mic"),
                       "Studio Mic unavailable — may be in use")
    }
}
