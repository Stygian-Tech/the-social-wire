import AsyncHTTPClient
import Foundation
import NIOCore

/// Resolves the HTTPS base a standard.site publication serves its documents from.
protocol PublicationSiteBaseResolving: Sendable {
  func siteBase(forPublicationAtUri atUri: String) async throws -> String?
}

/// Reads the publication record from its author PDS to recover the site base.
///
/// standard.site documents reference their publication by AT-URI, so the hosted article URL
/// cannot be built from the document record alone. Results are cached per publication — including
/// failures — so a backfill of many documents costs at most one lookup per publication.
actor LivePublicationSiteBaseResolver: PublicationSiteBaseResolving {
  private static let positiveTTL: TimeInterval = 6 * 60 * 60
  private static let negativeTTL: TimeInterval = 10 * 60
  private static let maxEntries = 512

  private let transport: any PDSHTTPTransport
  private let plcBase: String
  private let endpointPolicy: PDSResolvedEndpointPolicy
  private var cache: [String: (base: String?, expiresAt: Date)] = [:]

  init(
    transport: any PDSHTTPTransport,
    plcBase: String,
    endpointPolicy: PDSResolvedEndpointPolicy = .publicHTTPS
  ) {
    self.transport = transport
    self.plcBase = plcBase
    self.endpointPolicy = endpointPolicy
  }

  init(
    httpClient: HTTPClient,
    plcBase: String,
    endpointPolicy: PDSResolvedEndpointPolicy = .publicHTTPS
  ) {
    self.init(
      transport: LivePDSHTTPTransport(httpClient: httpClient),
      plcBase: plcBase,
      endpointPolicy: endpointPolicy
    )
  }

  func siteBase(forPublicationAtUri atUri: String) async throws -> String? {
    try Task.checkCancellation()
    guard
      let parsed = RenderFieldExtractor.parseAtUri(atUri),
      RenderFieldExtractor.publicationRecordCollections.contains(parsed.collection),
      let key = RenderFieldExtractor.canonicalPublicationAtUriKey(atUri)
    else { return nil }

    let now = Date()
    if let cached = cache[key], cached.expiresAt > now {
      return cached.base
    }

    let base: String?
    do {
      base = try await fetchSiteBase(
        repoDid: parsed.did,
        collection: parsed.collection,
        rkey: parsed.rkey
      )
    } catch {
      try Task.checkCancellation()
      base = nil
    }
    try Task.checkCancellation()
    store(base, forKey: key, now: now)
    return base
  }

  private func store(_ base: String?, forKey key: String, now: Date) {
    if cache.count >= Self.maxEntries, cache[key] == nil {
      cache.removeAll(keepingCapacity: true)
    }
    let ttl = base == nil ? Self.negativeTTL : Self.positiveTTL
    cache[key] = (base, now.addingTimeInterval(ttl))
  }

  private func fetchSiteBase(
    repoDid: String,
    collection: String,
    rkey: String
  ) async throws -> String? {
    let pdsBase: String?
    do {
      pdsBase = try await ThinAppViewPdsResolution.resolvePdsBase(
        repoDid: repoDid,
        plcBase: plcBase,
        transport: transport,
        endpointPolicy: endpointPolicy
      )
    } catch {
      try Task.checkCancellation()
      return nil
    }
    guard let pdsBase,
          var components = URLComponents(string: "\(pdsBase)/xrpc/com.atproto.repo.getRecord")
    else { return nil }

    components.queryItems = [
      URLQueryItem(name: "repo", value: repoDid),
      URLQueryItem(name: "collection", value: collection),
      URLQueryItem(name: "rkey", value: rkey),
    ]
    guard let url = components.url?.absoluteString else { return nil }

    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")
    let response: HTTPClientResponse
    do {
      response = try await transport.execute(request, timeout: .seconds(10))
    } catch {
      try Task.checkCancellation()
      return nil
    }
    guard response.status == .ok else {
      do {
        try await HTTPResponseBodyDrain.drainOrCancel(response.body)
      } catch {
        try Task.checkCancellation()
      }
      return nil
    }

    let body: ByteBuffer
    do {
      body = try await response.body.collect(upTo: 64 * 1024)
    } catch {
      try Task.checkCancellation()
      return nil
    }
    try Task.checkCancellation()
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let value = json["value"] as? [String: Any]
    else { return nil }

    return RenderFieldExtractor.publicationSiteBaseUrl(fromPublicationRecord: value)
  }
}
