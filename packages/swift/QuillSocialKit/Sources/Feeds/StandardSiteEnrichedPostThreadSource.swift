import ATProtoCore
import Foundation

public struct StandardSiteEnrichedPostThreadSource: PostThreadSource {
    public typealias Resolver = @Sendable (URL) async -> StandardSiteEmbedMetadata?
    public typealias TangledResolver = @Sendable (URL) async -> TangledStringEmbedMetadata?
    public typealias AtmoResolver = @Sendable (URL) async -> AtmoRsvpEmbedMetadata?

    private let base: any PostThreadSource
    private let resolver: Resolver
    private let tangledResolver: TangledResolver
    private let atmoResolver: AtmoResolver

    public init(
        base: any PostThreadSource,
        resolver: @escaping Resolver,
        tangledResolver: @escaping TangledResolver = { _ in nil },
        atmoResolver: @escaping AtmoResolver = { _ in nil }
    ) {
        self.base = base
        self.resolver = resolver
        self.tangledResolver = tangledResolver
        self.atmoResolver = atmoResolver
    }

    public func thread(uri: ATURI) async throws -> PostThread {
        let thread = try await base.thread(uri: uri)
        let entries = await withTaskGroup(of: (Int, ThreadEntry).self) { group in
            for (index, entry) in thread.entries.enumerated() {
                group.addTask { (index, await enrich(entry)) }
            }
            var enriched: [(Int, ThreadEntry)] = []
            for await result in group {
                enriched.append(result)
            }
            return enriched.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return PostThread(entries: entries)
    }

    private func enrich(_ entry: ThreadEntry) async -> ThreadEntry {
        async let externalEmbed = enrich(entry.post.externalEmbed)
        async let quote = enrich(entry.post.quote)
        let post = entry.post
            .replacingExternalEmbed(await externalEmbed)
            .replacingQuote(await quote)
        return ThreadEntry(
            post: post,
            depth: entry.depth,
            isFocused: entry.isFocused,
            replyingTo: entry.replyingTo
        )
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
