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
      let publicationURI = publicationURI(from: record)
      let publication = try await optionalPublication(
        publicationURI: publicationURI,
        publicationResolver: publicationResolver,
        asOf: asOf
      )
      return WireResolvedStandardSiteDocument(
        canonicalURL: normalized,
        publicationURI: publicationURI,
        publicationName: publication?.name,
        publicationHomepageURL: publication?.siteURL
      )
    }
    guard let path = firstString(record, keys: ["path"])
    else {
      if isValidUnaddressableDocument(record) {
        throw WireStandardSiteDocumentError.unaddressableDocument
      }
      throw WireStandardSiteDocumentError.malformedDocument
    }
    if let site = firstString(record, keys: ["site", "siteUrl", "homepage"]),
      let articleURL = WireStandardSiteURL.articleURL(path: path, publicationBase: site)
    {
      return WireResolvedStandardSiteDocument(
        canonicalURL: articleURL,
        publicationURI: nil,
        publicationName: nil,
        publicationHomepageURL: WireStandardSiteURL.publicationBase(from: ["url": site])
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
      publicationName: publication.name,
      publicationHomepageURL: publication.siteURL
    )
  }

  private static func optionalPublication(
    publicationURI: String?,
    publicationResolver: any WirePublicationResolving,
    asOf: Date
  ) async throws -> WirePublicationMetadata? {
    guard let publicationURI else { return nil }
    do {
      return try await publicationResolver.resolve(publicationURI: publicationURI, asOf: asOf)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A canonical document URL is independently authoritative. Publication
      // branding is best-effort here and can be filled by a later observation.
      return nil
    }
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

  private static func isValidUnaddressableDocument(_ record: [String: Any]) -> Bool {
    guard
      let site = firstString(record, keys: ["site"]),
      firstString(record, keys: ["title"]) != nil,
      firstString(record, keys: ["publishedAt"]) != nil
    else { return false }
    return WirePublicationReference.parse(site) != nil
      || WireStandardSiteURL.publicationBase(from: ["url": site]) != nil
  }
}
