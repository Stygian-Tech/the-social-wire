import Foundation

public enum ThinAppViewCursor {
  static func encode(createdAt: Date, uri: String) -> String {
    let iso = ISO8601DateFormatter().string(from: createdAt)
    return "\(iso)|\(uri)"
  }

  static func decode(_ cursor: String) -> (createdAt: Date, uri: String)? {
    guard let pipe = cursor.firstIndex(of: "|") else { return nil }
    let iso = String(cursor[..<pipe])
    let uri = String(cursor[cursor.index(after: pipe)...])
    guard !uri.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: iso) else { return nil }
    return (date, uri)
  }
}

public enum ThinAppViewQuerySupport {
  public static func parseISO8601Date(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    return ISO8601DateFormatter().date(from: raw)
  }

  static func entryListItems(from rows: [(uri: String, renderJSON: String, createdAt: Date)]) -> [AppViewEntryListItem] {
    let decoder = JSONDecoder()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoBasic = ISO8601DateFormatter()

    return rows.compactMap { row in
      guard
        let data = row.renderJSON.data(using: .utf8),
        let render = try? decoder.decode(ContentRenderFields.self, from: data)
      else { return nil }

      let publishedAt = iso.date(from: render.publishedAt)
        ?? isoBasic.date(from: render.publishedAt)
        ?? row.createdAt

      return AppViewEntryListItem(
        entryId: row.uri,
        title: render.title,
        summary: render.summary,
        publishedAt: publishedAt,
        thumbnailUrl: render.thumbnailUrl,
        thumbnailFallbackUrl: nil
      )
    }
  }

  static func publicationSiteMatches(
    siteField: String?,
    publicationAtUri: String?,
    publicationScopeAtUris: [String] = [],
    publicationSiteUrls: [String] = []
  ) -> Bool {
    guard publicationAtUri != nil || !publicationScopeAtUris.isEmpty else { return true }
    return RenderFieldExtractor.matchesPublication(
      siteField: siteField,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
  }
}

extension ContentRenderFields {
  func encodedJSON() throws -> String {
    let data = try JSONEncoder().encode(self)
    guard let string = String(data: data, encoding: .utf8) else {
      throw ThinAppViewStoreError.encodingFailed
    }
    return string
  }
}

public enum ThinAppViewStoreError: Error {
  case encodingFailed
}
