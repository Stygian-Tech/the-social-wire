import SwiftUI

/// Sidebar: shows folders as sections; each folder contains its publications.
struct FolderListView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedPublication?.publicationId },
            set: { id in
                if let id, let pub = viewModel.publications.first(where: { $0.publicationId == id }) {
                    viewModel.selectPublication(pub)
                }
            }
        )) {
            // All Publications (unfoldered)
            Section("All Publications") {
                ForEach(unfolderedPublications) { pub in
                    PublicationRowView(publication: pub)
                        .tag(pub.publicationId)
                }
            }

            // Named folders
            ForEach(viewModel.folders) { folder in
                Section(folder.name) {
                    ForEach(publications(in: folder)) { pub in
                        PublicationRowView(publication: pub)
                            .tag(pub.publicationId)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.publications.isEmpty && viewModel.folders.isEmpty {
                ContentUnavailableView(
                    "No Publications",
                    systemImage: "newspaper",
                    description: Text("Follow accounts on Bluesky, then tap Refresh.")
                )
            }
        }
    }

    private var unfolderedPublications: [PublicationModel] {
        viewModel.publications.filter { $0.folderId == nil }
    }

    private func publications(in folder: FolderModel) -> [PublicationModel] {
        viewModel.publications.filter { $0.folderId == folder.id }
    }
}

struct PublicationRowView: View {
    let publication: PublicationModel

    var body: some View {
        Label {
            Text(publication.title)
                .lineLimit(1)
        } icon: {
            AsyncImage(url: publication.avatarURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
        }
    }
}
