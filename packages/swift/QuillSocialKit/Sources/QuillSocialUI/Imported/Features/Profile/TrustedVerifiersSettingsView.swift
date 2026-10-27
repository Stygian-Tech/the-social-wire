#if os(iOS)
import SwiftData
import SwiftUI

struct TrustedVerifiersSettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @State private var handle = ""
    @State private var typeahead = ActorTypeaheadModel()
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var pendingRemoval: String?
    @State private var selectedProfiles: [String: ActorTypeaheadResult] = [:]
    @State private var showsContentProviderRequirement = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Bluesky Verification", isOn: blueskyVerificationBinding)
                    Toggle("Verify Jerry", isOn: verifiesJerryBinding)
                } footer: {
                    Text("Bluesky Verification can be disabled in favor of your selected trusted verifiers. Verify Jerry controls whether Jerry Chen receives a verification badge.")
                }

                Section("Add Verifier") {
                    TextField("Handle", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { addVerifier() }

                    ForEach(availableSuggestions) { actor in
                        Button {
                            addVerifier(did: actor.did)
                        } label: {
                            HStack(spacing: 10) {
                                AsyncImage(url: actor.avatar) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Image(systemName: "person.crop.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(.circle)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(actor.displayName ?? actor.handle)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("@\(actor.handle)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                }

                Section("Selected Accounts") {
                    if verifierDIDs.isEmpty {
                        ContentUnavailableView(
                            "No Custom Verifiers",
                            systemImage: "checkmark.seal",
                            description: Text("Bluesky verification remains enabled.")
                        )
                    } else {
                        ForEach(verifierDIDs, id: \.self) { did in
                            HStack {
                                if let profile = selectedProfiles[did] {
                                    AsyncImage(url: profile.avatar) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "person.crop.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 36, height: 36)
                                    .clipShape(.circle)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(profile.displayName ?? profile.handle)
                                            .lineLimit(1)
                                        Text("@\(profile.handle)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                } else {
                                    Image(systemName: "person.crop.circle")
                                        .foregroundStyle(.secondary)
                                    Text(did)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    pendingRemoval = did
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                }
            }
            .roundedNavigationTitle("Trusted Verifiers")
            .onChange(of: handle) { _, value in
                typeahead.search(value)
            }
            .task(id: verifierDIDs) {
                await loadSelectedProfiles()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn’t Add Verifier", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please check the handle and try again.")
            }
            .alert(
                "Choose Another Content Provider",
                isPresented: $showsContentProviderRequirement
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Select a Content Provider other than Bluesky before turning off Bluesky Verification.")
            }
            .confirmationDialog(
                "Remove Trusted Verifier?",
                isPresented: removalBinding,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let pendingRemoval { remove(pendingRemoval) }
                }
            }
        }
    }

    private var verifierDIDs: [String] {
        settings.first?.trustedVerifierDIDs ?? []
    }

    private var blueskyVerificationBinding: Binding<Bool> {
        Binding(
            get: { settings.first?.includesBlueskyVerification ?? true },
            set: { value in
                let appSettings = settings.first ?? AppSettings()
                if settings.first == nil { modelContext.insert(appSettings) }
                guard value || appSettings.canDisableBlueskyVerification else {
                    showsContentProviderRequirement = true
                    return
                }
                appSettings.includesBlueskyVerification = value
                try? modelContext.save()
            }
        )
    }

    private var verifiesJerryBinding: Binding<Bool> {
        Binding(
            get: { settings.first?.verifiesJerry ?? true },
            set: { value in
                let appSettings = settings.first ?? AppSettings()
                if settings.first == nil { modelContext.insert(appSettings) }
                appSettings.verifiesJerry = value
                try? modelContext.save()
            }
        )
    }

    private var availableSuggestions: [ActorTypeaheadResult] {
        typeahead.results.filter { !verifierDIDs.contains($0.did) }
    }

    private func addVerifier() {
        let actor = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty, !isResolving else { return }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let data = try await services.appViewRequest(
                    "app.bsky.actor.getProfile",
                    ["actor": actor]
                )
                let profile = try JSONDecoder().decode(ActorTypeaheadResult.self, from: data)
                let appSettings = settings.first ?? AppSettings()
                if settings.first == nil { modelContext.insert(appSettings) }
                if !appSettings.trustedVerifierDIDs.contains(profile.did) {
                    appSettings.trustedVerifierDIDs.append(profile.did)
                    try modelContext.save()
                }
                selectedProfiles[profile.did] = profile
                handle = ""
                typeahead.clear()
            } catch {
                errorMessage = "The Social Wire couldn’t resolve that account."
            }
        }
    }

    private func addVerifier(did: String) {
        let appSettings = settings.first ?? AppSettings()
        if settings.first == nil { modelContext.insert(appSettings) }
        guard !appSettings.trustedVerifierDIDs.contains(did) else { return }
        appSettings.trustedVerifierDIDs.append(did)
        try? modelContext.save()
        if let profile = typeahead.results.first(where: { $0.did == did }) {
            selectedProfiles[did] = profile
        }
        handle = ""
        typeahead.clear()
    }

    private func remove(_ did: String) {
        settings.first?.trustedVerifierDIDs.removeAll { $0 == did }
        try? modelContext.save()
        pendingRemoval = nil
    }

    private func loadSelectedProfiles() async {
        for did in verifierDIDs where selectedProfiles[did] == nil {
            guard let data = try? await services.appViewRequest(
                "app.bsky.actor.getProfile",
                ["actor": did]
            ), let profile = try? JSONDecoder().decode(ActorTypeaheadResult.self, from: data) else {
                continue
            }
            selectedProfiles[did] = profile
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }
}

#endif
