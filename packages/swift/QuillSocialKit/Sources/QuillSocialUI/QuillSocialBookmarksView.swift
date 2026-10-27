#if os(iOS)
import Feeds
import SwiftUI

struct QuillSocialBookmarksView: View {
    @Environment(AppServices.self) private var services
    @State private var timeline: TimelineModel?

    var body: some View {
        Group {
            if let timeline {
                FeedRouteView(timeline: timeline)
            } else {
                ProgressView("Loading Bookmarks")
            }
        }
        .roundedNavigationTitle("Bookmarks")
        .task {
            guard timeline == nil else { return }
            let request = services.appViewRequest
            timeline = TimelineModel(source: ATProtoTimelineSource { parameters in
                let data = try await request("app.bsky.bookmark.getBookmarks", parameters)
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let bookmarks = object.removeValue(forKey: "bookmarks") as? [[String: Any]] else {
                    throw URLError(.cannotParseResponse)
                }
                object["feed"] = bookmarks.compactMap { bookmark -> [String: Any]? in
                    guard let post = bookmark["item"] as? [String: Any] else { return nil }
                    return ["post": post]
                }
                return try JSONSerialization.data(withJSONObject: object)
            })
        }
    }
}
#endif
