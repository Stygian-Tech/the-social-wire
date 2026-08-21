import Foundation

enum WireStandardSiteDocumentResolver {
  static func resolve(
    record: [String: Any],
    publicationResolver: any WirePublicationResolving,
    asOf: Date
  ) async throws -> WireResolvedStandardSiteDocument {
    if let directURL = firstString(
      record, keys: ["canonicalUrl", "url", "externalUrl", "href", "permalink"]),
      let normalized = WireStandardSiteURL.articleURL(path: directURL, publicationBase: directURL)
    {
      return WireResolvedStandardSiteDocument(
        canonicalURL: normalized,
        publicationURI: publicationURI(from: record),
        publicationName: nil
      )
    }
    guard let path = firstString(record, keys: ["path"])
    else { throw WireStandardSiteDocumentError.malformedDocument }
    if let site = firstString(record, keys: ["site", "siteUrl", "homepage"]),
      let articleURL = WireStandardSiteURL.articleURL(path: path, publicationBase: site)
    {
      return WireResolvedStandardSiteDocument(
        canonicalURL: articleURL,
        publicationURI: nil,
        publicationName: nil
      )
    }
    guard let publicationURI = publicationURI(from: record)
    else { throw WireStandardSiteDocumentError.malformedDocument }
    let publication: WirePublicationMetadata?
    do {
      publication = try await publicationResolver.resolve(
        publicationURI: publicationURI, asOf: asOf)
    } catch is CancellationError {
      throw CancellationError()
    } catch WirePublicationQueryError.invalidDID,
      WirePublicationQueryError.unsafeEndpoint,
      WirePublicationQueryError.responseTooLarge,
      WirePublicationQueryError.invalidResponse
    {
      throw WireStandardSiteDocumentError.invalidPublication
    } catch {
      throw WireStandardSiteDocumentError.unresolvedPublication
    }
    guard let publication,
      let articleURL = WireStandardSiteURL.articleURL(
        path: path, publicationBase: publication.siteURL)
    else { throw WireStandardSiteDocumentError.unresolvedPublication }
    return WireResolvedStandardSiteDocument(
      canonicalURL: articleURL,
      publicationURI: publication.publicationURI,
      publicationName: publication.name
    )
  }

  private static func publicationURI(from record: [String: Any]) -> String? {
    for key in ["site", "publication", "publicationUri", "publicationId"] {
      if let value = record[key] as? String,
        let reference = WirePublicationReference.parse(value)
      {
        return reference.uri
      }
      if let object = record[key] as? [String: Any],
        let value = object["uri"] as? String,
        let reference = WirePublicationReference.parse(value)
      {
        return reference.uri
      }
    }
    return nil
  }

  private static func firstString(_ record: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = record[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }
}
