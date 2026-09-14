import SwiftUI

struct SavedLinkRow: View {
    @Environment(SocialWireAppModel.self) private var appModel

    let save: MergedLatrSave
    var isSelected: Bool = false

    var body: some View {
        ArticleListRow(
            model: ArticleListRowModel(
                title: save.title,
                summary: save.excerpt,
                subtitle: save.rowSubtitle,
                thumbnailURLs: save.image.flatMap(URL.init(string:)).map { [$0] } ?? [],
                publication: appModel.resolvedSavedLinkPublicationChip(for: save),
                reason: nil,
                reasonAccessibilityLabel: nil,
                tags: save.tags,
                isRead: false,
                showsReadState: false
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
