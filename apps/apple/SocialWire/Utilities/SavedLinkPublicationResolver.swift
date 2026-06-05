import Foundation

struct SavedLinkPublicationChipModel: Equatable, Sendable {
    var name: String
    var faviconURL: URL?
    var homepageURL: URL?
}

enum SavedLinkPublicationResolver {
    static func resolve(for save: MergedLatrSave, sidebarPublications: [DiscoveredPublication]) -> SavedLinkPublicationChipModel? {
        if let matched = matchFromSidebar(save: save, sidebarPublications: sidebarPublications) {
            return matched
        }
        return resolveFromMetadata(save: save)
    }

    private static func matchFromSidebar(
        save: MergedLatrSave,
        sidebarPublications: [DiscoveredPublication]
    ) -> SavedLinkPublicationChipModel? {
        let articleHosts = articleHostKeys(for: save)
        if !articleHosts.isEmpty {
            for publication in sidebarPublications {
                if let site = publicationSiteHost(for: publication.publicationId),
                   articleHosts.contains(site)
                {
                    return chip(from: publication)
                }
            }
        }

        if case .native(let native) = save,
           let authorDid = parseAuthorDid(from: native.subjectUri)
        {
            let matches = sidebarPublications.filter { $0.authorDid == authorDid }
            if matches.count == 1, let publication = matches.first {
                return chip(from: publication)
            }
        }
        return nil
    }

    private static func resolveFromMetadata(save: MergedLatrSave) -> SavedLinkPublicationChipModel? {
        if let site = save.site?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty {
            let name = siteDisplayName(site)
            let homepage = SavedLinkEmbedURL.previewURL(for: save).flatMap { URL(string: $0.originString) }
            return SavedLinkPublicationChipModel(
                name: name,
                faviconURL: homepage.map { $0.appending(path: "favicon.ico") },
                homepageURL: homepage
            )
        }
        if let url = SavedLinkEmbedURL.previewURL(for: save), let host = url.host {
            return SavedLinkPublicationChipModel(
                name: host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression),
                faviconURL: URL(string: "\(url.scheme ?? "https")://\(host)/favicon.ico"),
                homepageURL: URL(string: "\(url.scheme ?? "https")://\(host)")
            )
        }
        return nil
    }

    private static func chip(from publication: DiscoveredPublication) -> SavedLinkPublicationChipModel {
        SavedLinkPublicationChipModel(
            name: publication.title,
            faviconURL: publication.iconUrl.flatMap(URL.init(string:))
                ?? publication.avatarUrl.flatMap(URL.init(string:)),
            homepageURL: publicationSiteURL(for: publication)
        )
    }

    private static func articleHostKeys(for save: MergedLatrSave) -> Set<String> {
        var keys = Set<String>()
        for candidate in [
            SavedLinkEmbedURL.resolveEmbedURL(for: save),
            save.linkedWebUrl,
            save.site,
        ] {
            guard let candidate, let key = siteHostKey(candidate) else { continue }
            keys.insert(key)
        }
        return keys
    }

    private static func siteHostKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let urlString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    private static func siteDisplayName(_ site: String) -> String {
        let trimmed = site.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http"), let key = siteHostKey(trimmed) {
            return key
        }
        return trimmed
    }

    private static func parseAuthorDid(from subjectURI: String) -> String? {
        let trimmed = subjectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("at://") else { return nil }
        let parts = trimmed.dropFirst("at://".count).split(separator: "/", maxSplits: 1)
        return parts.first.map(String.init)
    }

    private static func publicationSiteHost(for publicationId: String) -> String? {
        guard publicationId.lowercased().hasPrefix("http"), let key = siteHostKey(publicationId) else {
            return nil
        }
        return key
    }

    private static func publicationSiteURL(for publication: DiscoveredPublication) -> URL? {
        if publication.publicationId.lowercased().hasPrefix("http") {
            return URL(string: publication.publicationId)
        }
        return nil
    }
}

private extension URL {
    var originString: String {
        guard let scheme, let host else { return absoluteString }
        return "\(scheme)://\(host)"
    }
}
