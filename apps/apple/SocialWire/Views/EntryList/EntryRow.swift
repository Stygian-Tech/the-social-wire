import SwiftUI

struct EntryRow: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let entry: EntryListItem
    let isRead: Bool
    let showsReadState: Bool
    var style: ArticleFeedCardStyle = .row

    var body: some View {
        switch style {
        case .lead:
            ArticleLeadCard(model: rowModel)
        case .grid:
            ArticleGridCard(model: rowModel)
        case .row:
            ArticleListRow(model: rowModel)
        }
    }

    private var rowModel: ArticleListRowModel {
        ArticleListRowModel(
            title: entry.title,
            summary: entry.summary,
            subtitle: entry.displayPublishedAt,
            thumbnailURLs: ThumbnailImageURLAttempts.candidates(
                primary: entry.thumbnailUrl,
                fallback: entry.thumbnailFallbackUrl
            ),
            publication: publicationChip,
            reason: entry.wireMetadata?.primaryReasonLabel,
            reasonAccessibilityLabel: entry.wireMetadata?.reasonLabels.joined(separator: ", "),
            tags: [],
            isRead: isRead,
            showsReadState: showsReadState
        )
    }

    private var publicationChip: SavedLinkPublicationChipModel? {
        if let wire = entry.wireMetadata {
            return SavedLinkPublicationChipModel(
                name: wire.source.displayName,
                faviconURL: PublicationSiteFavicon.url(for: wire.source.domain).flatMap(URL.init(string:)),
                homepageURL: URL(string: "https://\(wire.source.domain)")
            )
        }
        guard let publicationId = entry.publicationId,
              let publication = appModel.publication(forId: publicationId) else { return nil }
        return SavedLinkPublicationChipModel(
            name: publication.title,
            faviconURL: publication.displayImageURLs.first,
            homepageURL: nil
        )
    }
}
