import SwiftUI

private struct SuppressesNewsContentActionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var suppressesNewsContentActions: Bool {
        get { self[SuppressesNewsContentActionsKey.self] }
        set { self[SuppressesNewsContentActionsKey.self] = newValue }
    }
}
