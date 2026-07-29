import XCTest
import SwiftUI
@testable import OratorKit

/// The Settings pane is a fixed-size window whose height must follow its content.
///
/// It carried a hardcoded `height: 540` from when the vocabulary list lived at the bottom and grew as
/// the user added terms — the fixed height existed so that growth scrolled internally instead of
/// pushing the window. With that section gone, the constant only produced dead space.
final class SettingsLayoutTests: XCTestCase {

    /// The height SwiftUI actually wants for the pane's content.
    @MainActor
    private func fittingHeight() -> CGFloat {
        let view = SettingsView(language: LanguageModel(selectedID: "en-US"))
        let hosting = NSHostingController(rootView: view)
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.height
    }

    /// Guards the regression directly: the pane must not report the old hardcoded height, and must
    /// land in a range that is plausibly "the content" rather than a collapsed or runaway layout.
    @MainActor
    func testPaneHeightFollowsItsContent() {
        let height = fittingHeight()
        print("Settings content fitting height: \(height)")
        XCTAssertGreaterThan(height, 150, "a collapsed pane means the Form lost its intrinsic height")
        XCTAssertLessThan(height, 540, "the pane should no longer carry the vocabulary-era fixed height")
    }
}
