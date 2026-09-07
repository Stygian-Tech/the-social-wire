import SwiftUI

struct ArticleBodyUnavailableView: View {
    @Environment(\.openURL) private var openURL
    let originalURL: URL?

    var body: some View {
        ContentUnavailableView {
            Label("Reader Unavailable", systemImage: "doc.text")
        } description: {
            Text(description)
        } actions: {
            if let originalURL {
                Button("Open Original Article") {
                    openURL(originalURL)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var description: String {
        if originalURL == nil {
            "This story doesn't include readable article content or an original link."
        } else {
            "This story doesn't include readable article content, but you can continue on the publisher's website."
        }
    }
}
