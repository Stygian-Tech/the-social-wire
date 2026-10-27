#if os(iOS)
import ATProtoCore
import Feeds
import SwiftUI

struct QuotedPostView: View {
    let quote: TimelineQuote

    @Environment(\.routeNavigator) private var navigator

    var body: some View {
        QuotedPostCardView(
            quote: quote,
            onOpenThread: openThreadAction
        )
    }

    private var openThreadAction: (() -> Void)? {
        guard let action = Self.threadAction(for: quote, navigator: navigator) else { return nil }
        return {
            Task { @MainActor in
                await action()
            }
        }
    }

    static func threadAction(
        for quote: TimelineQuote,
        navigator: RouteNavigator?
    ) -> (@MainActor () async -> Void)? {
        guard let uri = try? ATURI(quote.uri), let navigator else { return nil }
        return {
            await Task.yield()
            navigator(.thread(uri))
        }
    }
}

#endif
