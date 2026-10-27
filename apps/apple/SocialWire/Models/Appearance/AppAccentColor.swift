import SwiftUI

enum AppAccentColor: String, CaseIterable, Identifiable {
    static let storageKey = "the-social-wire.accent-color.v1"

    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case blue
    case indigo
    case purple
    case pink

    var id: Self { self }
    var title: String { rawValue.capitalized }

    init(storedRawValue: String) {
        self = Self(rawValue: storedRawValue) ?? .indigo
    }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }
}
