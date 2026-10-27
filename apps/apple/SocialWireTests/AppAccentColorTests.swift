import SwiftUI
import Testing
@testable import SocialWire

@Suite("App Accent Color")
struct AppAccentColorTests {
    @Test("New or unrecognized preferences keep the existing indigo theme")
    func unknownPreferenceFallsBackToIndigo() {
        #expect(AppAccentColor(storedRawValue: "") == .indigo)
        #expect(AppAccentColor(storedRawValue: "retired-color") == .indigo)
    }

    @Test("Every selectable color restores from its persisted value", arguments: AppAccentColor.allCases)
    func persistedSelectionRestores(color: AppAccentColor) {
        #expect(AppAccentColor(storedRawValue: color.rawValue) == color)
    }
}
