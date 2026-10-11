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
        return show.feedUrl != nil && record["feedUrl"]?.string == show.feedUrl
            || show.sourceUri != nil && record["externalRef"]?.string == show.sourceUri
    }
}
