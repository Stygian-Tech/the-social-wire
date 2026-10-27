#if os(iOS)
import Feeds
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import QuillSocialUI

@MainActor
struct ComposerReferencedPostTests {
    @Test("Reply and quote previews use full width and show attached media immediately",
          arguments: [CGFloat(320), CGFloat(700)], [false, true])
    func fullPostPreview(width: CGFloat, quoting: Bool) throws {
        let schema = Schema([AppSettings.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        ))
        let services = TestAppServices.make()
        let url = try #require(URL(string: "https://image.example/photo.jpg"))
        func measure(images: [TimelineImage]) -> CGSize {
            let post = TimelinePost(
                uri: "at://did:plc:fixture/app.bsky.feed.post/preview", cid: "fixture",
                author: TimelineAuthor(did: "did:plc:fixture", handle: "fixture.example"),
                text: "perfect, no notes",
                createdAt: Date(timeIntervalSince1970: 0),
                images: images
            )
            let host = UIHostingController(rootView:
                ComposerReferencedPostView(title: quoting ? "Quoting" : "Replying To", post: post, initiallyExpanded: true)
                    .modelContainer(container)
                    .environment(services)
                    .environment(\.dynamicTypeSize, .large)
            )
            return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        let text = measure(images: [])
        let photo = measure(images: [
            TimelineImage(thumbnailURL: url, fullsizeURL: url, altText: "Photo", width: 600, height: 600)
        ])
        #expect(abs(text.width - width) < 1)
        #expect(abs(photo.width - width) < 1)
        // A collapsed two-line summary has the same height regardless of attachments.
        #expect(photo.height - text.height > width / 2)
    }
}

#endif
