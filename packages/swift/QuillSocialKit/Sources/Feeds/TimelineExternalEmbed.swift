import Foundation

public struct TimelineExternalEmbed: Hashable, Sendable {
    public let uri: URL
    public let title: String
    public let description: String
    public let thumbnailURL: URL?
    public let standardSite: StandardSiteEmbedMetadata?
    public let tangledString: TangledStringEmbedMetadata?
    public let atmoRsvp: AtmoRsvpEmbedMetadata?

    /// External GIF embeds keep the animated source in the URI; App View thumbnails are stills.
    public var animatedGIFURL: URL? {
        if uri.pathExtension.lowercased() == "gif", ["https", "http"].contains(uri.scheme?.lowercased() ?? "") {
            return uri
        }
        if let thumbnailURL, thumbnailURL.pathExtension.lowercased() == "gif" {
            return thumbnailURL
        }
        return nil
    }

    public var gifAspectRatio: Double? {
        guard animatedGIFURL != nil,
              let items = URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems,
              let widthValue = items.first(where: { $0.name == "ww" })?.value,
              let heightValue = items.first(where: { $0.name == "hh" })?.value,
              let width = Double(widthValue), let height = Double(heightValue),
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return width / height
    }

    public var displaySiteName: String? {
        if let publicationName = standardSite?.publicationName
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !publicationName.isEmpty {
            return publicationName
        }

        guard var host = uri.host, !host.isEmpty else { return nil }
        if host.lowercased().hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    public init(
        uri: URL,
        title: String,
        description: String,
        thumbnailURL: URL? = nil,
        standardSite: StandardSiteEmbedMetadata? = nil,
        tangledString: TangledStringEmbedMetadata? = nil,
        atmoRsvp: AtmoRsvpEmbedMetadata? = nil
    ) {
        self.uri = uri
        self.title = title
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.standardSite = standardSite
        self.tangledString = tangledString
        self.atmoRsvp = atmoRsvp
    }

    public func attachingStandardSite(_ metadata: StandardSiteEmbedMetadata?) -> Self {
        Self(
            uri: uri, title: title, description: description, thumbnailURL: thumbnailURL,
            standardSite: metadata, tangledString: tangledString, atmoRsvp: atmoRsvp
        )
    }

    public func attachingTangledString(_ metadata: TangledStringEmbedMetadata?) -> Self {
        Self(
            uri: uri, title: title, description: description, thumbnailURL: thumbnailURL,
            standardSite: standardSite, tangledString: metadata, atmoRsvp: atmoRsvp
        )
    }

    public func attachingAtmoRsvp(_ metadata: AtmoRsvpEmbedMetadata?) -> Self {
        Self(
            uri: uri, title: title, description: description, thumbnailURL: thumbnailURL,
            standardSite: standardSite, tangledString: tangledString, atmoRsvp: metadata
        )
    }
}
