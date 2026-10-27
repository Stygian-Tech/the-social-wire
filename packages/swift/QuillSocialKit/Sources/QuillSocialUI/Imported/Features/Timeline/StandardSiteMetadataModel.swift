#if os(iOS)
import Foundation
import Feeds
import Observation

@MainActor
@Observable
final class StandardSiteMetadataModel {
    private static let cache = StandardSiteMetadataCache()

    typealias Metadata = StandardSiteEmbedMetadata

    enum Resolution: Sendable {
        case standardSite(Metadata)
        case ordinaryLink
        case unavailable
    }

    private(set) var metadata: Metadata?

    func load(articleURL: URL) async {
        guard metadata == nil else { return }
        metadata = await Self.cache.metadata(for: articleURL)
    }

    nonisolated static func resolve(articleURL: URL) async -> Metadata? {
        guard case .standardSite(let metadata) = await classify(articleURL: articleURL) else {
            return nil
        }
        return metadata
    }

    nonisolated static func classify(articleURL: URL) async -> Resolution {
        var articleRequest = URLRequest(url: articleURL, timeoutInterval: 6)
        articleRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: articleRequest),
              let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode,
              let html = String(data: data, encoding: .utf8) else { return .unavailable }
        guard let documentURI = linkTarget(rel: "site.standard.document", in: html) else {
            return .ordinaryLink
        }
        guard documentURI.hasPrefix("at://"),
              let components = URLComponents(url: articleURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host,
              let publicationURL = URL(string: "\(scheme)://\(host)") else { return .unavailable }

        let publicationURI: String
        if let linkedPublication = linkTarget(rel: "site.standard.publication", in: html),
           linkedPublication.hasPrefix("at://") {
            publicationURI = linkedPublication
        } else {
            let documentData = try? await ATProtoPublicRepository.record(uri: documentURI)
            let documentObject = documentData.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let documentValue = documentObject?["value"] as? [String: Any]
            if let documentPublication = documentValue?["site"] as? String,
               documentPublication.hasPrefix("at://") {
                publicationURI = documentPublication
            } else {
                let wellKnown = publicationURL.appending(path: ".well-known/site.standard.publication")
                guard let (uriData, _) = try? await URLSession.shared.data(from: wellKnown),
                      let discoveredPublication = String(data: uriData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      discoveredPublication.hasPrefix("at://") else { return .unavailable }
                publicationURI = discoveredPublication
            }
        }

        let publicationData = try? await ATProtoPublicRepository.record(uri: publicationURI)
        let publicationObject = publicationData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let publicationValue = publicationObject?["value"] as? [String: Any]
        let name = publicationValue?["name"] as? String
            ?? metaContent(property: "og:site_name", in: html)
            ?? host
        let resolvedPublicationURL = (publicationValue?["url"] as? String).flatMap(URL.init(string:))
            ?? publicationURL
        let iconReference = ((publicationValue?["icon"] as? [String: Any])?["ref"] as? [String: Any])?["$link"] as? String
        let publicationDID = publicationURI.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first.map(String.init)
        let recordIcon: URL? = if let publicationDID, let iconReference {
            try? await ATProtoPublicRepository.blobURL(did: publicationDID, cid: iconReference)
        } else { nil }
        let icon = recordIcon ?? linkTarget(relContaining: "icon", in: html)
            .flatMap { URL(string: $0, relativeTo: articleURL)?.absoluteURL }
        let documentAuthor = documentURI.split(separator: "/", omittingEmptySubsequences: true)
            .dropFirst().first.map(String.init)
        let authorProfile: AuthorProfile? = if let documentAuthor {
            await profile(for: documentAuthor)
        } else { nil }
        return .standardSite(Metadata(
            publicationName: name,
            publicationURL: resolvedPublicationURL,
            publicationURI: publicationURI,
            documentURI: documentURI,
            logoURL: icon,
            authorName: authorProfile?.name,
            authorAvatarURL: authorProfile?.avatarURL
        ))
    }

    private nonisolated static func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private nonisolated static func profile(for actor: String) async -> AuthorProfile? {
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile")!
        components.queryItems = [URLQueryItem(name: "actor", value: actor)]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let name = profile["displayName"] as? String ?? profile["handle"] as? String else { return nil }
        return AuthorProfile(
            name: name,
            avatarURL: (profile["avatar"] as? String).flatMap(URL.init(string:))
        )
    }

    private struct AuthorProfile: Sendable {
        let name: String
        let avatarURL: URL?
    }

    private nonisolated static func linkTarget(rel: String, in html: String) -> String? {
        tags(named: "link", in: html).first { attributes in
            attributes["rel"]?.split(whereSeparator: { $0.isWhitespace })
                .contains(where: { $0.caseInsensitiveCompare(rel) == .orderedSame }) == true
        }?["href"]
    }

    private nonisolated static func linkTarget(relContaining value: String, in html: String) -> String? {
        tags(named: "link", in: html).first { attributes in
            attributes["rel"]?.localizedCaseInsensitiveContains(value) == true
        }?["href"]
    }

    private nonisolated static func metaContent(property: String, in html: String) -> String? {
        tags(named: "meta", in: html).first { attributes in
            attributes["property"]?.caseInsensitiveCompare(property) == .orderedSame
                || attributes["name"]?.caseInsensitiveCompare(property) == .orderedSame
        }?["content"]
    }

    nonisolated static func tags(named name: String, in html: String) -> [[String: String]] {
        guard let tagExpression = try? NSRegularExpression(
            pattern: "<\(name)\\b[^>]*>",
            options: .caseInsensitive
        ), let attributeExpression = try? NSRegularExpression(
            pattern: #"([A-Za-z_:.-]+)\s*=\s*["']([^"']*)["']"#,
            options: .caseInsensitive
        ) else { return [] }

        return tagExpression.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
            guard let tagRange = Range(match.range, in: html) else { return [:] }
            let tag = String(html[tagRange])
            return Dictionary(attributeExpression.matches(
                in: tag,
                range: NSRange(tag.startIndex..., in: tag)
            ).compactMap { attribute in
                guard let keyRange = Range(attribute.range(at: 1), in: tag),
                      let valueRange = Range(attribute.range(at: 2), in: tag) else { return nil }
                return (String(tag[keyRange]).lowercased(), String(tag[valueRange]))
            }, uniquingKeysWith: { first, _ in first })
        }
    }
}

#endif
