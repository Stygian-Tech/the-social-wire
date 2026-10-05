import SwiftUI

struct SportsCustomizationView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    private let initialEntity: SportsEntity?
    @State private var pendingReference: String?
    @State private var pendingAction: String?
    @State private var showingDisclosure = false
    @State private var showingRemoval = false
    @State private var acceptedDisclosure = false

    init(initialEntity: SportsEntity? = nil) {
        self.initialEntity = initialEntity
        _query = State(initialValue: initialEntity?.name ?? "")
    }

    private var topic: SportsTopicModel { appModel.sportsTopic }
    private var results: [SportsEntity] {
        if let initialEntity, query == initialEntity.name { return [initialEntity].filter(\.isSelectable) }
        let candidates = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (topic.catalog?.entities.filter { $0.kind == "sport" } ?? []) : topic.searchResults
        return candidates.filter(\.isSelectable)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show Sports", isOn: Binding(get: { appModel.feedPreferences.showSports }, set: { value in
                        Task { await appModel.setSportsVisible(value) }
                    }))
                    Toggle("Hide Scores", isOn: Binding(get: { appModel.feedPreferences.hideSportsScores }, set: { value in
                        Task { await appModel.setSportsScoresHidden(value) }
                    }))
                    Text("Hides event scores and results. Article headlines and images may reveal results.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sports Interests") {
                    TextField("Search Sports, Competitions, Teams, or People", text: $query)
                    ForEach(results) { entity in
                        Menu {
                            Button("Follow") { choose(entity.id, action: "follow") }
                            Button("Mute") { choose(entity.id, action: "mute") }
                            if topic.selections.contains(where: { $0.reference == entity.id }) {
                                Button("Remove Interest", role: .destructive) { pendingReference = entity.id; showingRemoval = true }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(entity.displayName, systemImage: entity.systemImage)
                                    Text(detail(entity)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let selection = topic.selections.first(where: { $0.reference == entity.id }) {
                                    Text(selection.action == "mute" ? "Muted" : "Following").font(.caption)
                                }
                            }
                        }
                        .disabled(topic.isSaving || !entity.active)
                    }
                }
                Section("Public Interests") {
                    Text("Follows and mutes are public PDS records that others may copy. Removal deletes your record and app projection, but cannot erase downstream copies. Following expresses an interest, not affiliation.")
                        .font(.footnote)
                    ForEach(topic.selections, id: \.key) { selection in
                        HStack {
                            Text(topic.catalog?.entities.first { $0.id == selection.reference }?.displayName ?? "Unavailable Interest")
                            Spacer()
                            Text(selection.action == "mute" ? "Muted" : "Following").font(.caption)
                            Button("Remove Interest", systemImage: "trash", role: .destructive) {
                                pendingReference = selection.reference; showingRemoval = true
                            }.labelStyle(.iconOnly).disabled(topic.isSaving)
                        }
                    }
                    Text("Following a team or person overrides a broader sport or competition mute. Explicitly muted teams and people stay hidden.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = topic.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Customize Sports")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { try? await topic.reconcileSelections() }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await topic.search(query)
            }
            .alert("Public Sports Interests", isPresented: $showingDisclosure) {
                Button("Cancel", role: .cancel) { pendingReference = nil }
                Button("Save Public Interest") { acceptedDisclosure = true; savePending() }
            } message: {
                Text("This follow or mute will be publicly stored on your PDS. Others may copy it; removal cannot erase downstream copies. It expresses an interest, not affiliation.")
            }
            .confirmationDialog("Remove This Public Interest?", isPresented: $showingRemoval, titleVisibility: .visible) {
                Button("Remove Interest", role: .destructive) { pendingAction = nil; savePending() }
                Button("Cancel", role: .cancel) { pendingReference = nil }
            }
        }
    }

    private func detail(_ entity: SportsEntity) -> String {
        let sport = topic.catalog?.entities.first { $0.id == entity.sportID }?.displayName
        let competitions = entity.competitionIDs.compactMap { id in topic.catalog?.entities.first { $0.id == id }?.displayName }
        return ([entity.kind.capitalized] + [sport].compactMap { $0 } + competitions).joined(separator: " · ")
    }

    private func choose(_ reference: String, action: String) {
        pendingReference = reference; pendingAction = action
        if acceptedDisclosure { savePending() } else { showingDisclosure = true }
    }

    private func savePending() {
        guard let pendingReference else { return }
        let action = pendingAction
        Task { await topic.setSelection(reference: pendingReference, action: action) }
    }
}
