import SwiftUI

struct SportsFeedPickerView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var topic: SportsTopicModel { appModel.sportsTopic }
    private var followedFeeds: [SportsNamedFeed] {
        SportsNamedFeed.followedFeeds(topic.catalog?.feeds ?? [], entities: topic.catalog?.entities ?? [],
                                     selections: topic.selections)
    }
    private var groups: [SportsFeedPickerGroup] {
        SportsFeedPickerGroup.make(
            feeds: topic.catalog?.feeds ?? [.all],
            selectedID: topic.selectedFeedID,
            query: query,
            activeEntityIDs: Set((topic.catalog?.entities ?? []).filter(\.active).map(\.id)),
            aliasesByEntityID: Dictionary((topic.catalog?.entities ?? []).map { ($0.id, $0.aliases) }, uniquingKeysWith: { first, _ in first })
        )
    }

    var body: some View {
        let roots = SportsFeedPickerNode.make(feeds: topic.catalog?.feeds ?? [.all], entities: topic.catalog?.entities ?? [])
        NavigationStack {
            browser(title: "Sports Feeds", nodes: roots, feed: nil, showsFollowing: true)
                .navigationDestination(for: String.self) { id in
                    if let node = roots.lazy.compactMap({ $0.find(id) }).first {
                        browser(title: SportsEntity.displayName(node.title, kind: node.kind), nodes: node.children, feed: node.feed)
                    }
                }
        }
    }

    private func browser(title: String, nodes: [SportsFeedPickerNode], feed: SportsNamedFeed?, showsFollowing: Bool = false) -> some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return List {
            if searching {
                ForEach(groups) { group in
                    Section(group.title) { ForEach(group.feeds) { selectionRow($0) } }
                }
            } else {
                if showsFollowing, !followedFeeds.isEmpty {
                    Section("Following in Sports") {
                        ForEach(followedFeeds) { selectionRow($0) }
                    }
                }
                if let feed { Section { selectionRow(feed) } }
                ForEach(nodes) { node in
                    if node.children.isEmpty, let feed = node.feed {
                        selectionRow(feed)
                    } else {
                        NavigationLink(value: node.id) { Label(SportsEntity.displayName(node.title, kind: node.kind), systemImage: icon(node.kind)) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search Sports, Conferences, or Teams")
        .overlay { if searching && groups.isEmpty { ContentUnavailableView.search(text: query) } }
        .navigationTitle(title)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func selectionRow(_ feed: SportsNamedFeed) -> some View {
        Button {
            Task { await topic.selectFeed(feed.id, language: Locale.current.language.languageCode?.identifier ?? "en") }
            dismiss()
        } label: {
            HStack {
                Label(SportsEntity.displayName(feed.title, kind: feed.kind), systemImage: icon(feed.kind))
                Spacer()
                if topic.selectedFeedID == feed.id { Image(systemName: "checkmark") }
            }
        }
        .accessibilityAddTraits(topic.selectedFeedID == feed.id ? .isSelected : [])
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "competition": "trophy"
        case "classification": "figure.pool.swim"
        case "team", "national-side", "ncaa-team": "person.3.fill"
        case "athlete", "driver": "person.fill"
        default: "sportscourt"
        }
    }
}
