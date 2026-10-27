#if os(iOS)
import Feeds
import SwiftUI

struct StoryPageView: View {
    let author: StoryAuthor
    let story: StoryRecord

    @State private var mediaURL: URL?

    var body: some View {
        Group {
            if let mediaURL {
                AsyncImage(url: mediaURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    case .failure:
                        ContentUnavailableView("Story Unavailable", systemImage: "photo.badge.exclamationmark")
                    default:
                        ProgressView()
                    }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: story.id) {
            mediaURL = try? await ATProtoPublicRepository.blobURL(
                did: author.did,
                cid: story.blobCID
            )
        }
    }
}

#endif
