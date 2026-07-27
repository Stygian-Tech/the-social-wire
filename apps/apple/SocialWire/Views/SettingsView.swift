import SwiftUI

struct SettingsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// When pushed from **Profile**, use the navigation back button instead of **Done**.
    var showsDoneButton: Bool = true

    var body: some View {
        Form {
            Section("Visible Feeds") {
                ForEach(ReaderListSource.allCases) { source in
                    let isVisible = appModel.visibleReaderListSources.contains(source)
                    Toggle(
                        source.rawValue,
                        isOn: Binding(
                            get: { isVisible },
                            set: { value in
                                Task {
                                    await appModel.setFeedVisible(source, visible: value)
                                }
                            }
                        )
                    )
                    .disabled(isVisible && appModel.visibleReaderListSources.count == 1)
                }
            }

            Section("Unread Counts") {
                Toggle(
                    "Show Feed Unread Counts",
                    isOn: Binding(
                        get: { appModel.showTopLevelFeedUnreadCounts },
                        set: { value in
                            Task {
                                await appModel.setShowTopLevelFeedUnreadCounts(value)
                            }
                        }
                    )
                )
            }

            Section("Account") {
                LabeledContent("DID", value: appModel.viewerDID ?? "")
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
