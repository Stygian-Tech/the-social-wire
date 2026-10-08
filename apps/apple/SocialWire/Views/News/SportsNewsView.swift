import SwiftUI

struct SportsNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @State private var scrollAnchor: String?
    @State private var showingPicker = false
    @State private var showingCustomization = false

    private var topic: SportsTopicModel { appModel.sportsTopic }
    private var selectedEntity: SportsEntity? {
        guard let feed = topic.selectedFeed, feed.entityIDs.count == 1, let id = feed.entityIDs.first else { return nil }
        return topic.catalog?.entities.first { $0.id == id }
    }
    private var language: String { Locale.current.language.languageCode?.identifier ?? "en" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { showingPicker = true } label: {
                        Label(selectedEntity?.displayName ?? topic.selectedTitle, systemImage: "sportscourt")
                            .font(.headline)
                    }
                    Spacer()
                    Button("Customize", systemImage: "slider.horizontal.3") { showingCustomization = true }
                        .labelStyle(.iconOnly)
                }
                if topic.selectedFeedID != "sports" {
                    HStack {
                        Text("Only Stories Matching This Feed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let entity = selectedEntity, entity.isSelectable {
                            let following = topic.selections.contains { $0.reference == entity.id && $0.action == "follow" }
                            Button(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus") { showingCustomization = true }
                                .buttonStyle(.bordered).disabled(topic.isSaving)
                        }
                    }
                }
                if let entity = selectedEntity, topic.selectedFeedID != "sports" {
                    SportsEntityOverview(entity: entity, events: topic.events, eventsError: topic.eventsError,
                        eventsEnabled: topic.catalog?.eventsEnabled == true, hideScores: appModel.feedPreferences.hideSportsScores,
                        entities: topic.catalog?.entities ?? [])
                    Text("Latest News").font(.headline)
                } else {
                    Text("Schedule")
                        .font(.title2.bold())
                    if topic.selectedFeedID == "sports" {
                    Picker("Schedules and Standings", selection: Binding(get: { topic.eventScope }, set: { value in
                        Task { await topic.setEventScope(value) }
                    })) {
                        Text(topic.allPreferredEventIDs.isEmpty ? "All Sports" : "Your Sports").tag("all")
                        Text("My Sports").tag("sports")
                        Text("My Leagues").tag("leagues")
                        Text("My Teams").tag("teams")
                    }.pickerStyle(.segmented)
                    }
                    if topic.catalog == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 72)
                    } else {
                        SportsEventsStrip(events: topic.events, error: topic.eventsError, hideScores: appModel.feedPreferences.hideSportsScores, entities: topic.catalog?.entities ?? [])
                    }
                }
                if let error = topic.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { Task { await refresh() } }
                }
                if topic.isLoading, topic.items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                } else if topic.items.isEmpty {
                    ContentUnavailableView("No Matching Stories Yet", systemImage: "sportscourt",
                        description: Text("Sports Stories Will Appear Here When Available."))
                }
                ForEach(topic.items) { item in
                    WireStoryCard(entry: item.story.toEntryListItem()) {
                        if let url = URL(string: item.story.canonicalUrl) { openURL(url) }
                    }
                    .id(item.id)
                    SportsStoryActions(item: item)
                }
                if topic.continuationSuspended {
                    Button("Refresh Personalized Feed") { Task { await refresh() } }
                } else if let cursor = topic.page?.cursor {
                    Button("More Stories") { Task { await topic.load(language: language, cursor: cursor) } }
                        .disabled(topic.isLoading)
                }
            }
            .scrollTargetLayout()
            .padding()
            .frame(maxWidth: ArticleReadingWidth.editorial)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $scrollAnchor)
        .refreshable { await refresh() }
        .onChange(of: topic.selectedFeedID) { _, _ in scrollAnchor = nil }
        .sheet(isPresented: $showingPicker) { SportsFeedPickerView() }
        .sheet(isPresented: $showingCustomization) { SportsCustomizationView(initialEntity: selectedEntity) }
    }

    private func refresh() async {
        await topic.load(language: language)
        await topic.loadEvents()
    }
}
