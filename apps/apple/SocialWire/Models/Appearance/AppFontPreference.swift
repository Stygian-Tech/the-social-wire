import SwiftUI

enum AppFontPreference: String, CaseIterable, Identifiable {
    case sans
    case serif
    case mono

    var id: Self { self }

    var title: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .sans: .default
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}
