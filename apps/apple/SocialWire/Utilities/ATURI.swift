import Foundation

struct ATURI: Equatable, Sendable {
    let repo: String
    let collection: String
    let rkey: String

    init?(_ raw: String) {
        guard raw.hasPrefix("at://") else { return nil }
        let rest = raw.dropFirst("at://".count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return nil }
        repo = parts[0]
        collection = parts[1]
        rkey = parts[2]
    }
}

func rkey(from uri: String) -> String {
    uri.split(separator: "/").last.map(String.init) ?? uri
}

private func urlDecodedOnce(_ value: String) -> String? {
    guard let decoded = value.removingPercentEncoding, decoded != value else { return nil }
    return decoded
}

private func decodeUriEncodingLayers(_ segment: String) -> String {
    var segment = segment
    for _ in 0 ..< 3 {
        guard segment.contains("%"),
              let decoded = segment.removingPercentEncoding,
              decoded != segment
        else { break }
        segment = decoded
    }
    return segment
}

private func decodeAtUriAuthorityAndCollection(_ uri: String) -> String? {
    guard uri.hasPrefix("at://") else { return nil }
    let components = uri
        .dropFirst("at://".count)
        .split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 3, components.allSatisfy({ !$0.isEmpty }) else { return nil }

    let auth = String(components[0])
    let coll = String(components[1])
    let rkey = String(components[2])
    let decodedAuth = decodeUriEncodingLayers(auth)
    let decodedColl = decodeUriEncodingLayers(coll)
    guard decodedAuth != auth || decodedColl != coll else { return nil }
    return "at://\(decodedAuth)/\(decodedColl)/\(rkey)"
}

/// Normalizes sidebar/route publication keys (trim, strip `@`, decode URL-encoded AT-URIs).
func normalizeATRepoParam(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("@") {
        value = String(value.dropFirst())
    }
    for _ in 0 ..< 3 {
        if value.hasPrefix("did:") {
            return value
        }
        if let decodedAtUri = decodeAtUriAuthorityAndCollection(value), decodedAtUri != value {
            value = decodedAtUri
            continue
        }
        guard let decoded = urlDecodedOnce(value), decoded != value else {
            return value
        }
        value = decoded
    }
    return value
}

func canonicalPublicationAtUriKey(_ uri: String) -> String? {
    guard let at = ATURI(normalizeATRepoParam(uri)) else { return nil }
    let repo = at.repo.lowercased().hasPrefix("did:plc:") ? at.repo.lowercased() : at.repo
    return "at://\(repo)/\(at.collection)/\(at.rkey)"
}

func repoAndPublicationFilter(from publicationId: String) -> (repoDid: String, publicationAtUri: String?) {
    let normalized = normalizeATRepoParam(publicationId)
    if let at = ATURI(normalized) {
        return (at.repo, normalized)
    }
    return (normalized, nil)
}
