#if os(iOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var hostAccountSettings: (() -> Void)? = nil
}
#endif
