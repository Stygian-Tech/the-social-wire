#if os(iOS)
import SwiftData
import SwiftUI

struct ContentProviderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @State private var selection = ContentProviderPreferences.blueskyProxy
    @State private var customDomain = ""
    @State private var errorMessage: String?
    @State private var showsRestartAlert = false
    @State private var hasLoadedSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    providerRow("Bluesky", proxy: ContentProviderPreferences.blueskyProxy)
                    providerRow("Blacksky", proxy: ContentProviderPreferences.blackskyProxy)
                    providerRow("Custom Domain", proxy: "custom")
                } header: {
                    Text("Content Provider")
                } footer: {
                    Text("Your Content Provider indexes posts, profiles, feeds, and social activity, and applies its moderation policies.")
                }

                if selection == "custom" || isCustomSelection {
                    Section("Custom Provider") {
                        TextField("api.example.com", text: $customDomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .roundedNavigationTitle("Content Provider")
            .onAppear { loadSettings() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert("Invalid Content Provider", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Enter a valid domain.")
            }
            .alert("Restart Required", isPresented: $showsRestartAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("Quit and reopen The Social Wire to use the selected Content Provider.")
            }
        }
    }

    private func providerRow(_ title: LocalizedStringKey, proxy: String) -> some View {
        Button {
            selection = proxy
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selectedProxy == proxy || (proxy == "custom" && isCustomSelection) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var isCustomSelection: Bool {
        selection != ContentProviderPreferences.blueskyProxy
            && selection != ContentProviderPreferences.blackskyProxy
    }

    private var selectedProxy: String {
        selection
    }

    private func save() {
        let proxy: String?
        if selection == "custom" || isCustomSelection {
            proxy = ContentProviderPreferences.proxy(forDomain: customDomain)
        } else {
            proxy = selection
        }
        guard let proxy else {
            errorMessage = "Enter the domain of a compatible AT Protocol Content Provider."
            return
        }
        let appSettings = settings.first ?? AppSettings()
        guard proxy != ContentProviderPreferences.blueskyProxy
            || appSettings.includesBlueskyVerification else {
            errorMessage = "Enable Bluesky Verification before selecting Bluesky as your Content Provider."
            return
        }
        if settings.first == nil { modelContext.insert(appSettings) }
        appSettings.contentProviderProxy = proxy
        try? modelContext.save()
        showsRestartAlert = true
    }

    private func loadSettings() {
        guard !hasLoadedSettings else { return }
        hasLoadedSettings = true
        let active = settings.first?.contentProviderProxy ?? ContentProviderPreferences.blueskyProxy
        selection = active
        if active != ContentProviderPreferences.blueskyProxy,
           active != ContentProviderPreferences.blackskyProxy {
            customDomain = active
                .replacingOccurrences(of: "did:web:", with: "")
                .replacingOccurrences(of: "#bsky_appview", with: "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

#endif
