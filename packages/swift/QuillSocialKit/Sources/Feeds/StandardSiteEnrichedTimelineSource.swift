import Foundation

public struct StandardSiteEnrichedTimelineSource: TimelineSource {
    public typealias Resolver = @Sendable (URL) async -> StandardSiteEmbedMetadata?
    public typealias TangledResolver = @Sendable (URL) async -> TangledStringEmbedMetadata?
    public typealias AtmoResolver = @Sendable (URL) async -> AtmoRsvpEmbedMetadata?

    private let base: any TimelineSource
    private let resolver: Resolver
    private let tangledResolver: TangledResolver
    private let atmoResolver: AtmoResolver

    public init(
        base: any TimelineSource,
        resolver: @escaping Resolver,
        tangledResolver: @escaping TangledResolver = { _ in nil },
        atmoResolver: @escaping AtmoResolver = { _ in nil }
    ) {
        self.base = base
        self.resolver = resolver
        self.tangledResolver = tangledResolver
        self.atmoResolver = atmoResolver
    }

    public func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
        try await timeline(cursor: cursor, limit: limit, onInitialPage: { _ in })
    }

    public func timeline(
        cursor: String?, limit: Int,
        onInitialPage: @escaping @Sendable (TimelinePage) async -> Void
    ) async throws -> TimelinePage {
        let page = try await base.timeline(cursor: cursor, limit: limit)
        try Task.checkCancellation()
        await onInitialPage(page)
        try Task.checkCancellation()
        let posts = await withTaskGroup(of: (Int, TimelinePost).self) { group in
            // A busy account can have dozens of links per page. Keep requests bounded
            // while the base page is already visible and usable.
            var nextIndex = 0
            let concurrency = min(4, page.posts.count)
            for index in 0..<concurrency {
                group.addTask { (index, await enrich(page.posts[index])) }
                nextIndex += 1
            }
            var enriched = page.posts
            for await (index, post) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enriched[index] = post
                if nextIndex < page.posts.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { (index, await enrich(page.posts[index])) }
                }
            }
            return enriched
        }
        try Task.checkCancellation()
        return TimelinePage(posts: posts, cursor: page.cursor)
    }

    private func enrich(_ post: TimelinePost) async -> TimelinePost {
        async let externalEmbed = enrich(post.externalEmbed)
        async let quote = enrich(post.quote)
        return post
            .replacingExternalEmbed(await externalEmbed)
            .replacingQuote(await quote)
    }

    private func enrich(_ embed: TimelineExternalEmbed?) async -> TimelineExternalEmbed? {
        guard let embed else { return nil }
        if isTangledString(embed.uri) {
            return embed.attachingTangledString(await tangledResolver(embed.uri))
        }
        if embed.uri.host?.lowercased() == "atmo.rsvp" {
            return embed.attachingAtmoRsvp(await atmoResolver(embed.uri))
        }
        async let standardSite = resolver(embed.uri)
        return embed
            .attachingStandardSite(await standardSite)
    }

    private func isTangledString(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "tangled.org" || host == "tangled.sh" else { return false }
        return url.pathComponents.dropFirst().first == "strings"
    }

    private func enrich(_ quote: TimelineQuote?) async -> TimelineQuote? {
        guard let quote else { return nil }
        return quote.replacingExternalEmbed(await enrich(quote.externalEmbed))
    }
}
