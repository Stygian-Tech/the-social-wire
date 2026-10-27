import SwiftUI

struct SocialBookmarksView: View {
    @Bindable var model: SocialCatalogModel
    let navigate: (SocialRoute) -> Void
    var body: some View {
        List(model.bookmarks) { post in
            Button { navigate(.post(uri: post.uri)) } label: { VStack(alignment: .leading) { Text(post.author.preferredName).font(.headline); Text(post.text).lineLimit(5) } }.buttonStyle(.plain)
        }
        .overlay { if model.isLoading && model.bookmarks.isEmpty { ProgressView() } else if let error = model.error, model.bookmarks.isEmpty { ContentUnavailableView("Bookmarks Unavailable", systemImage: "bookmark.slash", description: Text(error)) } }
        .task { if model.bookmarks.isEmpty { await model.loadBookmarks() } }
    }
}
