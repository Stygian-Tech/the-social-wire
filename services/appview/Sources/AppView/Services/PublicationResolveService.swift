import AsyncHTTPClient
import GatewayCore
import Foundation
import GatewayCore
import Hummingbird
import Logging
import ThinAppViewCore

/// Resolves pasted links into standard.site publication AT-URIs or RSS feed URLs.
/// Mirrors web `addPublicationResolveServer.ts` (subset sufficient for client parity).
actor PublicationResolveService {
  private let httpClient: HTTPClient
  private let plcURL: String
  private let logger: Logger
  private let repo: ATProtoAuthenticatedRepoClient

  init(httpClient: HTTPClient, plcURL: String, logger: Logger) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.logger = logger
    self.repo = ATProtoAuthenticatedRepoClient(httpClient: httpClient, plcURL: plcURL, logger: logger)
  }

  func resolve(input rawInput: String, auth: AuthContext?) async -> ResolveAddPublicationResponse {
    let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else {
      return ResolveAddPublicationResponse(result: nil, error: "Enter a link or publication reference.")
    }

    let atCandidate = PublicationProjectionLogic.normalizeAtRepoParam(input)
    if atCandidate.hasPrefix("at://") {
      return await resolveAtUri(atCandidate, auth: auth)
    }

    if input.contains("://") {
      return await resolveHttpsUrl(input, auth: auth)
    }

    if input.hasPrefix("did:") {
      if let pub = await probeFirstPublicationRecordUri(input, auth: auth) {
        return ResolveAddPublicationResponse(
          result: .standardSite(publicationAtUri: pub),
          error: nil
        )
      }
      return ResolveAddPublicationResponse(
        result: nil,
        error: "No site.standard.publication (or com.standard.publication) records found for that DID."
      )
    }

    if let probed = await probeFirstPublicationRecordUri(input, auth: auth) {
      return ResolveAddPublicationResponse(
        result: .standardSite(publicationAtUri: probed),
        error: nil
      )
    }

    let withScheme = "https://\(input)"
    if PublicationProjectionLogic.normalizeRssFeedUrl(withScheme) != nil {
      return await resolveHttpsUrl(withScheme, auth: auth)
    }

    return ResolveAddPublicationResponse(
      result: nil,
      error: "Could not interpret that as a Bluesky handle, DID, https URL, or publication AT-URI."
    )
  }

  // MARK: - Private

  private func resolveAtUri(_ atUri: String, auth: AuthContext?) async -> ResolveAddPublicationResponse {
    guard let parsed = RenderFieldExtractor.parseAtUri(atUri) else {
      return ResolveAddPublicationResponse(result: nil, error: "Invalid AT-URI.")
    }

    if parsed.collection == "app.offprint.publication" {
      if let value = try? await repo.getRecordByAtUri(auth: auth, atUri: atUri),
         let inner = (value.values["publication"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
         !inner.isEmpty
      {
        return ResolveAddPublicationResponse(
          result: .standardSite(publicationAtUri: PublicationProjectionLogic.normalizeAtRepoParam(inner)),
          error: nil
        )
      }
      return ResolveAddPublicationResponse(
        result: nil,
        error: "Offprint publication record is missing its site.standard.publication reference."
      )
    }

    if PublicationLexicons.publicationRecordCollections.contains(parsed.collection) {
      return ResolveAddPublicationResponse(result: .standardSite(publicationAtUri: atUri), error: nil)
    }

    return ResolveAddPublicationResponse(
      result: nil,
      error: "Unsupported AT-URI — use a publication record (site.standard.publication or com.standard.publication)."
    )
  }

  private func resolveHttpsUrl(_ input: String, auth: AuthContext?) async -> ResolveAddPublicationResponse {
    guard let normalized = PublicationProjectionLogic.normalizeRssFeedUrl(input) else {
      return ResolveAddPublicationResponse(result: nil, error: "invalid url")
    }

    guard let pageUrl = URL(string: normalized) else {
      return ResolveAddPublicationResponse(result: nil, error: "invalid url")
    }

    if let publication = await tryWellKnownPublication(origin: pageUrl) {
      return ResolveAddPublicationResponse(result: .standardSite(publicationAtUri: publication), error: nil)
    }

    if await looksLikeRssFeed(normalized) {
      return ResolveAddPublicationResponse(
        result: .rss(feedUrl: normalized, title: nil, siteUrl: pageUrl.host, feedIconUrl: nil),
        error: nil
      )
    }

    if let fromPage = await discoverRssFromPageUrl(pageUrl) {
      return ResolveAddPublicationResponse(
        result: .rss(feedUrl: fromPage, title: nil, siteUrl: pageUrl.host, feedIconUrl: nil),
        error: nil
      )
    }

    return ResolveAddPublicationResponse(
      result: nil,
      error:
        "Could not find a standard.site publication marker for this domain or a reachable RSS/Atom feed. Try a publication AT-URI or a direct feed URL."
    )
  }

  private func probeFirstPublicationRecordUri(_ handleOrDid: String, auth: AuthContext?) async -> String? {
    guard
      let did = try? await ATProtoPdsResolution.resolveRepoDid(
        handleOrDid: handleOrDid,
        httpClient: httpClient
      )
    else { return nil }

    for collection in PublicationLexicons.discoveryPublicationCollections {
      let page = try? await repo.listRecords(auth: auth, repo: did, collection: collection, limit: 1, reverse: true)
      if let uri = page?.records.first?.uri {
        return uri
      }
    }
    return nil
  }

  private func tryWellKnownPublication(origin: URL) async -> String? {
    let url = origin.appendingPathComponent(".well-known/site.standard.publication")
    var request = HTTPClientRequest(url: url.absoluteString)
    request.headers.add(name: "Accept", value: "text/plain, application/json")
    request.headers.add(name: "User-Agent", value: "the-social-wire/resolve-publication")

    guard
      let response = try? await httpClient.execute(request, timeout: .seconds(14)),
      response.status == .ok,
      let body = try? await response.body.collect(upTo: 4096)
    else { return nil }

    let text = String(buffer: body).trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("at://") else { return nil }

    let token = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
    let normalized = PublicationProjectionLogic.normalizeAtRepoParam(token)
    guard let parsed = RenderFieldExtractor.parseAtUri(normalized),
          PublicationLexicons.publicationRecordCollections.contains(parsed.collection)
    else { return nil }
    return normalized
  }

  private func looksLikeRssFeed(_ url: String) async -> Bool {
    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/rss+xml, application/atom+xml, application/xml, text/xml, */*")
    request.headers.add(name: "User-Agent", value: "the-social-wire/resolve-publication")

    guard
      let response = try? await httpClient.execute(request, timeout: .seconds(14)),
      [200, 403, 406, 415].contains(response.status.code),
      let body = try? await response.body.collect(upTo: 512 * 1024)
    else { return false }

    let lower = String(buffer: body).lowercased()
    return lower.contains("<rss") || lower.contains("<feed") || lower.contains("<channel")
  }

  private func discoverRssFromPageUrl(_ pageUrl: URL) async -> String? {
    var request = HTTPClientRequest(url: pageUrl.absoluteString)
    request.headers.add(name: "Accept", value: "text/html,application/xhtml+xml,application/xml")
    request.headers.add(name: "User-Agent", value: "the-social-wire/resolve-publication")

    guard
      let response = try? await httpClient.execute(request, timeout: .seconds(14)),
      response.status == .ok,
      let body = try? await response.body.collect(upTo: 1024 * 1024)
    else { return nil }

    let html = String(buffer: body)
    for href in collectAlternateFeedHrefs(html: html, base: pageUrl) {
      guard let norm = PublicationProjectionLogic.normalizeRssFeedUrl(href) else { continue }
      if await looksLikeRssFeed(norm) { return norm }
    }

    for path in ["/feed", "/feed.xml", "/rss", "/rss.xml", "/atom.xml", "/feeds/rss"] {
      guard let guess = URL(string: path, relativeTo: pageUrl)?.absoluteString,
            let norm = PublicationProjectionLogic.normalizeRssFeedUrl(guess)
      else { continue }
      if await looksLikeRssFeed(norm) { return norm }
    }
    return nil
  }

  private func collectAlternateFeedHrefs(html: String, base: URL) -> [String] {
    var out: [String] = []
    let tagPattern = #"<link\b[^>]*>"#
    let hrefPattern = #"\bhref\s*=\s*["']([^"']+)["']"#
    guard
      let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive),
      let hrefRegex = try? NSRegularExpression(pattern: hrefPattern, options: .caseInsensitive)
    else { return out }

    let range = NSRange(html.startIndex..., in: html)
    for match in tagRegex.matches(in: html, range: range) {
      guard let tagRange = Range(match.range, in: html) else { continue }
      let tag = String(html[tagRange]).lowercased()
      guard tag.contains("rel=\"alternate\"") || tag.contains("rel='alternate'") else { continue }
      let tagNS = NSRange(tag.startIndex..., in: tag)
      guard
        let hrefMatch = hrefRegex.firstMatch(in: tag, range: tagNS),
        hrefMatch.numberOfRanges > 1,
        let hrefRange = Range(hrefMatch.range(at: 1), in: tag)
      else { continue }
      let href = String(tag[hrefRange])
      if let resolved = URL(string: href, relativeTo: base)?.absoluteString {
        out.append(resolved)
      }
    }
    return Array(Set(out))
  }
}
