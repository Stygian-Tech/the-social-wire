import SwiftUI

struct SettingsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// When pushed from **Profile**, use the navigation back button instead of **Done**.
    var showsDoneButton: Bool = true
    @AppStorage("the-social-wire.theme.v1") private var themeRaw = AppThemePreference.system.rawValue
    @AppStorage("the-social-wire.font.v1") private var fontRaw = AppFontPreference.sans.rawValue
    @AppStorage("the-social-wire.bold-text.v1") private var boldText = false
    @State private var pendingReadLaterProvider = "latr-link"

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(AppThemePreference.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                Picker("Typography", selection: $fontRaw) {
                    ForEach(AppFontPreference.allCases) { font in
                        Text(font.title).tag(font.rawValue)
                    }
                }
                Toggle("Bold Text", isOn: $boldText)
            }

            Section("Articles") {
                Picker(
                    "Open Articles In",
                    selection: Binding(
                        get: { appModel.feedPreferences.articleOpenMode },
                        set: { mode in
                            Task { await appModel.setArticleOpenMode(mode) }
                        }
                    )
                ) {
                    ForEach(ArticleOpenMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text("Original Website opens the publisher's webpage by default. The Native Reader remains available from story actions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Saved") {
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { pendingReadLaterProvider },
                        set: { provider in
                            pendingReadLaterProvider = provider
                            if provider == "semble" {
                                Task { await appModel.loadOwnedSembleCollections() }
                            } else {
                                Task { await appModel.configureReadLater(serviceID: provider) }
                            }
                        }
                    )
                ) {
                    Text("L@tr Link").tag("latr-link")
                    Text("Semble").tag("semble")
                }

                if pendingReadLaterProvider == "semble" {
                    if appModel.isLoadingSemble && appModel.sembleCollections.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Loading Your Collections")
                        }
                    } else {
                        Picker(
                            "Collection",
                            selection: Binding<String?>(
                                get: { appModel.configuredSembleCollectionURI },
                                set: { uri in
                                    guard let uri,
                                          let collection = appModel.sembleCollections.first(where: { $0.uri == uri })
                                    else { return }
                                    Task {
                                        await appModel.configureReadLater(
                                            serviceID: "semble",
                                            sembleCollection: collection
                                        )
                                    }
                                }
                            )
                        ) {
                            Text("Choose a Collection").tag(String?.none)
                            ForEach(appModel.sembleCollections) { collection in
                                Text(collection.name).tag(Optional(collection.uri))
                            }
                        }
                    }

                    Text("Only collections owned by your signed-in account can be used for Saved. Choose a collection before Semble saves are enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Reload Collections", systemImage: "arrow.clockwise") {
                        Task { await appModel.loadOwnedSembleCollections() }
                    }
                }
            }

            Section("Feed Display") {
                ForEach(ReaderListSource.preferenceCases) { source in
                    let isVisible = appModel.visibleReaderListSources.contains(source)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.rawValue)
                            .font(.headline)
                        Toggle(
                            "Show Feed",
                            isOn: Binding(
                                get: { appModel.visibleReaderListSources.contains(source) },
                                set: { value in
                                    Task {
                                        await appModel.setFeedVisible(source, visible: value)
                                    }
                                }
                            )
                        )
                        .disabled(isVisible && appModel.visibleReaderListSources.count == 1)
                        Toggle(
                            "Show Count",
                            isOn: Binding(
                                get: { appModel.showsTopLevelFeedUnreadCount(for: source) },
                                set: { value in
                                    Task {
                                        await appModel.setFeedUnreadCountVisible(source, visible: value)
                                    }
                                }
                            )
                        )
                        .disabled(!isVisible)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Account") {
                LabeledContent("DID", value: appModel.viewerDID ?? "")
            }

            Section("Help") {
                NavigationLink {
                    UserInputFeedbackView()
                } label: {
                    Label("Send Feedback", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            pendingReadLaterProvider = appModel.isSembleReadLaterEnabled ? "semble" : "latr-link"
            if pendingReadLaterProvider == "semble" {
                await appModel.loadOwnedSembleCollections()
            }
        }
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
