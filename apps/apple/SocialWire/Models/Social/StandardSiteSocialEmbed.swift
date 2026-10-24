import Foundation

struct StandardSiteSocialEmbed: Decodable, Equatable, Sendable {
    let documentUri: String
    let publicationUri: String
    let publicationName: String
    let publicationUrl: URL
    let articleUrl: URL
    let title: String
    let description: String?
    let authorDid: String

    var isValid: Bool {
        documentUri.hasPrefix("at://")
            && documentUri.split(separator: "/").count == 4
            && ["site.standard.document", "site.standard.entry"].contains(String(documentUri.split(separator: "/")[2]))
            && publicationUri.hasPrefix("at://")
            && publicationUri.split(separator: "/").count == 4
            && publicationUri.split(separator: "/")[2] == "site.standard.publication"
            && Self.isHTTPS(articleUrl) && Self.isHTTPS(publicationUrl)
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    var entry: EntryDetail {
        EntryDetail(entryId: documentUri, title: title, publishedAt: "", contentHtml: "",
                    originalUrl: articleUrl.absoluteString)
    }

    var publication: DiscoveredPublication {
        DiscoveredPublication(publicationId: publicationUri, subscriptionPublicationId: publicationUri,
            authorDid: authorDid, authorHandle: "", title: publicationName,
            publicationSiteUrls: [publicationUrl.absoluteString], discoveredAt: "")
    }
}
