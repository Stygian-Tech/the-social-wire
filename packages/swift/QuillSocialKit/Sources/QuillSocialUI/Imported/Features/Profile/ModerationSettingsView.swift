#if os(iOS)
import SwiftData
import SwiftUI

struct ModerationSettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @State private var includesBluesky = true
    @State private var labelerDIDs: [String] = []
    @State private var search = ""
    @State private var typeahead = ActorTypeaheadModel()
    @State private var pendingRemoval: String?
    @State private var activeLabelerDIDs: [String] = []
    @State private var labelerProfiles: [String: ActorTypeaheadResult] = [:]
    @State private var loadError: String?
    @State private var isLoadingLabelers = true
    @State private var hasLoadedSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Bluesky Moderation", isOn: $includesBluesky)
                        .sensoryFeedback(.selection, trigger: includesBluesky)
                } footer: {
                    Text("Turn this off to rely solely on your Content Provider and other selected labelers.")
                }

                Section("Active Labelers") {
                    if isLoadingLabelers {
                        ProgressView()
                    } else if let loadError {
                        Text(loadError)
                            .foregroundStyle(.secondary)
                    } else if activeLabelerDIDs.isEmpty {
                        Text("No active labelers")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activeLabelerDIDs, id: \.self) { did in
                            labelerRow(did: did)
                        }
                    }
                }

                Section("Add Labeler") {
                    TextField("Search Accounts", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ForEach(typeahead.results.filter {
                        !labelerDIDs.contains($0.did) && !activeLabelerDIDs.contains($0.did)
                    }) { actor in
                        Button {
                            labelerDIDs.append(actor.did)
                            search = ""
                            typeahead.clear()
                        } label: {
                            Label(actor.displayName ?? actor.handle, systemImage: "plus.circle")
                        }
                    }
                }

                Section("Additional Labelers") {
                    if labelerDIDs.isEmpty {
                        Text("No additional labelers")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(labelerDIDs, id: \.self) { did in
                        HStack {
                            Text(did).lineLimit(1)
                            Spacer()
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                pendingRemoval = did
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
            }
            .onChange(of: search) { _, value in typeahead.search(value) }
            .task {
                loadSettings()
                await loadActiveLabelers()
            }
            .roundedNavigationTitle("Moderation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                }
            }
            .confirmationDialog(
                "Remove Labeler?",
                isPresented: removalBinding,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let pendingRemoval {
                        labelerDIDs.removeAll { $0 == pendingRemoval }
                    }
                    pendingRemoval = nil
                }
            }
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    @ViewBuilder
    private func labelerRow(did: String) -> some View {
        NavigationLink {
            LabelerModerationView(did: did)
        } label: {
            HStack(spacing: 10) {
                if let profile = labelerProfiles[did] {
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
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func loadActiveLabelers() async {
        defer { isLoadingLabelers = false }
        do {
            activeLabelerDIDs = try await services.activeLabelerDIDs()
            for did in activeLabelerDIDs {
                guard let data = try? await services.appViewRequest(
                    "app.bsky.actor.getProfile",
                    ["actor": did]
                ), let profile = try? JSONDecoder().decode(ActorTypeaheadResult.self, from: data) else {
                    continue
                }
                labelerProfiles[did] = profile
            }
        } catch {
            loadError = "The Social Wire couldn’t load your active labelers."
        }
    }

    private func loadSettings() {
        guard !hasLoadedSettings else { return }
        hasLoadedSettings = true
        includesBluesky = settings.first?.includesBlueskyModeration ?? true
        labelerDIDs = settings.first?.additionalLabelerDIDs ?? []
    }

    private func save() {
        let appSettings = settings.first ?? AppSettings()
        if settings.first == nil { modelContext.insert(appSettings) }
        appSettings.includesBlueskyModeration = includesBluesky
        appSettings.additionalLabelerDIDs = labelerDIDs
        try? modelContext.save()

        Task {
            await services.updateLabelerConfiguration(includesBluesky, labelerDIDs)
            dismiss()
        }
    }
}

#endif
