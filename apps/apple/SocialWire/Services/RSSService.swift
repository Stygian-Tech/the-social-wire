import Foundation

@MainActor
final class RSSService {
    func publicationID(normalizedFeedURL: String) -> String {
        "rss:\(normalizedFeedURL)"
    }

    func normalizedFeedURL(from publicationID: String) -> String? {
        publicationID.hasPrefix("rss:") ? String(publicationID.dropFirst(4)) : nil
    }

    func normalizeFeedURL(_ raw: String) -> String {
        PublicURLNormalizer.normalizeHttpURLToHTTPS(raw)
    }

    func discoveredPublication(from record: RepoRecord<SkyreaderFeedSubscriptionRecord>) -> DiscoveredPublication? {
        guard let rawFeed = record.value.feedUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFeed.isEmpty else {
            return nil
        }
        let normalized = normalizeFeedURL(rawFeed)
        let title = record.value.customTitle ?? record.value.title ?? URL(string: normalized)?.host ?? "RSS Feed"
        let icon = record.value.customIconUrl ?? record.value.siteUrl.flatMap { URL(string: $0)?.host.map { "https://\($0)/favicon.ico" } }
        return DiscoveredPublication(
            publicationId: publicationID(normalizedFeedURL: normalized),
            subscriptionPublicationId: record.uri,
            authorDid: "did:web:skyreader.rss",
            authorHandle: "RSS",
            title: title,
            iconUrl: icon,
            discoveredAt: record.value.updatedAt ?? record.value.createdAt
        )
    }

}
