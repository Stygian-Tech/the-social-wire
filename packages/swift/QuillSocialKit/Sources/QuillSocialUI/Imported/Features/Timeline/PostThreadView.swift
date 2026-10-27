#if os(iOS)
import ATProtoCore
import Feeds
import SwiftUI

struct PostThreadView: View {
    @State private var model: PostThreadModel

    init(uri: ATURI, source: any PostThreadSource) {
        model = PostThreadModel(uri: uri, source: source)
    }

    var body: some View {
        Group {
            if let thread = model.thread {
                ThreadEntriesView(thread: thread)
                    .refreshable { await model.refresh() }
            } else if model.didFail {
                ContentUnavailableView {
                    Label("Post Unavailable", systemImage: "exclamationmark.bubble")
                } description: {
                    Text("The Social Wire couldn’t load this conversation.")
                } actions: {
                    Button("Try Again") {
                        Task { await model.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Loading Conversation")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .videoPlaybackViewport()
        .task { await model.load() }
    }
}

#endif
