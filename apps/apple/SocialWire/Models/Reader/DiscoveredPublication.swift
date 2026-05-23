import Foundation

struct DiscoveredPublication: Identifiable, Codable, Equatable, Sendable {
    var publicationId: String
    var subscriptionPublicationId: String?
    var authorDid: String
    var authorHandle: String
    var title: String
    var iconUrl: String?
    var avatarUrl: String?
    var discoveredAt: String

    var id: String { publicationId }

    /// Publication icon first, then author avatar (matches gateway projection + web sidebar).
    var displayImageURL: URL? {
        for candidate in [iconUrl, avatarUrl] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { continue }
            let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS(raw)
            guard let url = URL(string: normalized) else { continue }
            return url
        }
        return nil
    }
}
