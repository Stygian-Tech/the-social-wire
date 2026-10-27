#if os(iOS)
import SwiftUI

struct ProfileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var showsDoneButton = true
    @State private var presentedSheet: ProfileSettingsSheet?

    var body: some View {
        List {
            ContentSafetySettingsSection(
                showContentProvider: { presentedSheet = .contentProvider },
                showModeration: { presentedSheet = .moderation },
                showTrustedVerifiers: { presentedSheet = .trustedVerifiers }
            )
            VideoPlaybackSettingsSection()
            AccessibilitySettingsSection()
        }
        .roundedNavigationTitle("Settings")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .contentProvider:
                ContentProviderSettingsView()
            case .moderation:
                ModerationSettingsView()
            case .trustedVerifiers:
                TrustedVerifiersSettingsView()
            }
        }
    }
}

#endif
