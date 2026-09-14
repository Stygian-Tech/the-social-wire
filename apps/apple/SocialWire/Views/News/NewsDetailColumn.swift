import SwiftUI

struct NewsDetailColumn: View {
    let route: NewsRoute?
    let tab: NewsTab
    let sceneModel: NewsSceneModel

    var body: some View {
        NavigationStack {
            if let route {
                NewsRouteDestination(route: route, tab: tab, sceneModel: sceneModel)
            } else {
                ContentUnavailableView(
                    "Select a Story",
                    systemImage: "doc.text",
                    description: Text("Choose a story from the middle column to start reading.")
                )
            }
        }
    }
}

struct NewsRouteDestination: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let route: NewsRoute
    let tab: NewsTab
    let sceneModel: NewsSceneModel

    var body: some View {
        switch route {
        case .entry(let id):
            if let entry = appModel.selectedEntry, entry.entryId == id {
                EntryDetailView(entry: entry)
            } else {
                ContentUnavailableView("Article Unavailable", systemImage: "doc.text")
            }
        case .publication(let id):
            PublicationFeedRouteView(publicationID: id, tab: tab, sceneModel: sceneModel)
        case .savedLink(let id):
            if let save = appModel.selectedSavedLink, save.id == id {
                SavedLinkDetailView(save: save)
            } else {
                ContentUnavailableView("Saved Link Unavailable", systemImage: "bookmark.slash")
            }
        case .sembleItem(let id):
            if let item = appModel.selectedSembleItem, item.id == id {
                SembleItemDetailView(item: item)
            } else if let item = appModel.sembleItems.first(where: { $0.id == id }) {
                SembleItemDetailView(item: item)
            } else {
                ContentUnavailableView("Semble Card Unavailable", systemImage: "square.stack.3d.up.slash")
            }
        case .profile:
            ProfileView()
        case .settings:
            SettingsView(showsDoneButton: false)
        }
    }
}

struct PublicationFeedRouteView: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let publicationID: String
    let tab: NewsTab
    let sceneModel: NewsSceneModel

    var body: some View {
        Group {
            if appModel.selectedPublication?.publicationId == publicationID {
                EntryListView(onEntryOpened: openSelectedEntry)
            } else if let publication = appModel.publication(forId: publicationID) {
                ProgressView()
                    .task(id: publicationID) {
                        await appModel.selectPublication(publication)
                    }
            } else {
                ContentUnavailableView("Publication Unavailable", systemImage: "newspaper")
            }
        }
        .navigationTitle(appModel.selectedPublication?.title ?? "Articles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let scope = ReaderMarkReadScope.publication(publicationId: publicationID)
                FeedMarkReadButton(
                    contextID: "\(appModel.viewerDID ?? ""):publication:\(publicationID)",
                    refreshRevision: appModel.readAgeRevision,
                    scopeTitle: appModel.selectedPublication?.title ?? "This Feed",
                    loadOptions: { try await appModel.readAgeOptions(for: scope) },
                    markAllRead: { await appModel.markRead(for: scope) },
                    markOlderRead: { try await appModel.markRead(for: scope, before: $0.before) },
                    markAllUnread: { await appModel.markUnread(for: scope) }
                )
            }
        }
    }

    private func openSelectedEntry() {
        guard let entryID = appModel.selectedEntry?.entryId else { return }
        sceneModel.navigate(to: .entry(id: entryID), in: tab)
    }
}
