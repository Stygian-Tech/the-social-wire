import Foundation

enum PodcastSubscriptionMatch {
    static func isPodcast(_ value: JSONValue) -> Bool {
        guard let record = value.object else { return false }
        let category = record["category"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !category.isEmpty { return category.caseInsensitiveCompare("podcast") == .orderedSame }
        let sourceType = record["sourceType"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceType?.caseInsensitiveCompare("atproto.collection") == .orderedSame,
              let source = record["externalRef"]?.string, let uri = ATURI(source) else { return false }
        guard source == "at://\(uri.repo)/\(uri.collection)/\(uri.rkey)" else { return false }
        return ["org.atpodcasting.podcast", "place.pod.show", "live.voxport.podcast.series"].contains(uri.collection)
    }

    static func matches(_ value: JSONValue, show: PodcastShow) -> Bool {
        guard isPodcast(value), let record = value.object else { return false }
        if let feed = show.feedUrl.flatMap(normalizedFeedURL),
           let subscribedFeed = record["feedUrl"]?.string.flatMap(normalizedFeedURL),
           feed == subscribedFeed { return true }
        return show.sourceUri != nil && record["externalRef"]?.string == show.sourceUri
    }

    private static func normalizedFeedURL(_ raw: String) -> String? {
        // Match AppView's NormalizeFeedURL so imported records retain their original rkeys.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasScheme = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
        guard var components = URLComponents(string: hasScheme ? trimmed : "https://\(trimmed)"),
              let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if scheme == "http" { components.scheme = "https" }
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard var normalized = components.string else { return nil }
        if normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }
}
