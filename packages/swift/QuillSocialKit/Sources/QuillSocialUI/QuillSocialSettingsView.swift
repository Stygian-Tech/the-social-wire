#if os(iOS)
import SwiftUI

/// Social preferences presented inside the host account's settings navigation.
public struct QuillSocialSettingsView: View {
    private let model: QuillSocialModel

    public init(model: QuillSocialModel) {
        self.model = model
    }

    public var body: some View {
        ProfileSettingsView(showsDoneButton: false)
            .environment(model.services)
            .modelContainer(model.settingsContainer)
    }
}
#endif
