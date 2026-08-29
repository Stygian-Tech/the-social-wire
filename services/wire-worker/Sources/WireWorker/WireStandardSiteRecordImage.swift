import Foundation

enum WireStandardSiteRecordImage {
  private static let directURLKeys = [
    "thumbnailUrl", "coverImageUrl", "image", "heroImage", "socialImage",
  ]

  static func directURL(from record: [String: Any]) -> String? {
    for key in ["coverImage", "thumbnail"] + directURLKeys {
      guard let value = record[key] as? String else { continue }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard var components = URLComponents(string: trimmed),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" || scheme == "http",
        let host = components.host?.lowercased(),
        components.user == nil,
        components.password == nil,
        WirePublicEndpointValidator.isPublicHostname(host)
      else { continue }
      components.scheme = "https"
      components.host = host
      return components.url?.absoluteString
    }
    return nil
  }

  static func blobCID(from record: [String: Any]) -> String? {
    for key in ["coverImage", "thumbnail"] {
      guard let cid = blobCID(from: record[key]) else { continue }
      return cid
    }
    return nil
  }

  static func resolveURL(
    from record: [String: Any],
    repoDID: String,
    blobURLResolver: (any WireBlobURLResolving)?
  ) async throws -> String? {
    let directURL = directURL(from: record)
    if let directURL { return directURL }
    guard let cid = blobCID(from: record), let blobURLResolver else { return nil }
    do {
      return try await blobURLResolver.resolveBlobURL(repoDID: repoDID, cid: cid)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil
    }
  }

  private static func blobCID(from value: Any?) -> String? {
    guard let object = value as? [String: Any] else { return nil }
    let raw =
      object["$link"] as? String
      ?? (object["ref"] as? [String: Any])?["$link"] as? String
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
    return trimmed
  }
}
