import SwiftUI

struct PublicationCollectionView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let title: String
    let publications: [DiscoveredPublication]

    var body: some View {
        List {
            if publications.isEmpty {
                ContentUnavailableView("No Publications", systemImage: "newspaper")
            } else {
                ForEach(publications) { publication in
                    Button {
                        Task { await appModel.selectPublication(publication) }
                    } label: {
                        HStack(spacing: 12) {
                            PublicationAvatar(publication: publication, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(publication.title)
                                    .font(.headline)
                                Text(publication.authorHandle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        FolderAssignmentMenu(publication: publication)
                        Button(publicationIsHidden(publication) ? "Unhide" : "Hide", systemImage: publicationIsHidden(publication) ? "eye" : "eye.slash") {
                            Task { await appModel.setHidden(publication, hidden: !publicationIsHidden(publication)) }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private func publicationIsHidden(_ publication: DiscoveredPublication) -> Bool {
        appModel.publicationPrefs[publication.publicationId]?.value.hidden ?? false
    }
}
