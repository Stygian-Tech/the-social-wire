#if os(iOS)
import SwiftUI

struct FeedThumbnailView: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "rectangle.stack.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(7)
        }
        .frame(width: 44, height: 44)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 10))
    }
}

#endif
