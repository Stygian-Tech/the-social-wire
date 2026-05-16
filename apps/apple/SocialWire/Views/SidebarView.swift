import SwiftUI

struct SidebarView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingAddPublication: Bool
    @Binding var showingNewFolder: Bool

    var body: some View {
        @Bindable var model = appModel

        List(selection: $model.selectedSidebar) {
            Section {
                Label("Reading List", systemImage: "newspaper")
                    .tag(SidebarSelection.readingList)
                Label("Saved Links", systemImage: "archivebox")
                    .tag(SidebarSelection.saved)
                Label("My Publications", systemImage: "person.crop.square")
                    .tag(SidebarSelection.myPublications)
            }

            Section("Folders") {
                ForEach(appModel.folders) { folder in
                    Label(folder.value.name, systemImage: "folder")
                        .tag(SidebarSelection.folder(folder.uri))
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task { await appModel.deleteFolder(folder) }
                            }
                        }
                }
                Button {
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }

            Section("Publications") {
                ForEach(appModel.unfolderedPublications) { publication in
                    PublicationSidebarRow(publication: publication)
                        .tag(SidebarSelection.publication(publication.publicationId))
                }
            }

            Section("More") {
                Label("Following", systemImage: "person.2")
                    .tag(SidebarSelection.following)
                Label("Hidden Publications", systemImage: "eye.slash")
                    .tag(SidebarSelection.hidden)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarSelection.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("The Social Wire")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingAddPublication = true
                } label: {
                    Label("Add Publication", systemImage: "plus")
                }
                Button {
                    Task { await appModel.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appModel.isLoading)
            }
        }
    }
}

struct PublicationSidebarRow: View {
    let publication: DiscoveredPublication

    var body: some View {
        HStack(spacing: 10) {
            PublicationAvatar(publication: publication, size: 24)
            Text(publication.title)
                .lineLimit(1)
        }
    }
}
