import AsyncHTTPClient
import Foundation
import NIOCore

actor HTTPWirePublicationQueryClient: WirePublicationQuerying, WireBlobURLResolving {
  private struct CachedPDSEndpoint: Sendable {
    let baseURL: String
    let expiresAt: Date
  }

  private let transport: any WirePublicationHTTPTransport
  private let dnsResolver: any WireDNSResolving
  private let plcDirectoryBase: URL
  private var pdsEndpointCache: [String: CachedPDSEndpoint] = [:]
  private var pdsEndpointTasks: [String: Task<String, Error>] = [:]

  init(httpClient: HTTPClient, plcDirectoryBase: URL = URL(string: "https://plc.directory")!) {
    self.init(
      transport: LiveWirePublicationHTTPTransport(httpClient: httpClient),
      dnsResolver: WirePublicDNSResolver(),
      plcDirectoryBase: plcDirectoryBase
    )
  }

  init(
    transport: any WirePublicationHTTPTransport,
    dnsResolver: any WireDNSResolving,
    plcDirectoryBase: URL
  ) {
    self.transport = transport
    self.dnsResolver = dnsResolver
    self.plcDirectoryBase = plcDirectoryBase
  }

  func query(publication: WirePublicationReference) async throws -> WirePublicationMetadata? {
    let pdsBase = try await pdsBase(for: publication.repoDID)

    var components = URLComponents(string: "\(pdsBase)/xrpc/com.atproto.repo.getRecord")
    components?.queryItems = [
      URLQueryItem(name: "repo", value: publication.repoDID),
      URLQueryItem(name: "collection", value: publication.collection),
      URLQueryItem(name: "rkey", value: publication.recordKey),
    ]
    guard let recordURL = components?.url else { throw WirePublicationQueryError.invalidResponse }
    try await validateDNS(for: recordURL)
    guard let document = try await jsonObject(at: recordURL, maximumBytes: 64 * 1024) else {
      return nil
    }
    guard let value = document["value"] as? [String: Any] else {
      throw WirePublicationQueryError.invalidResponse
    }
    guard
      let metadata = WirePublicationMetadata.parse(
        publicationURI: publication.uri,
        repoDID: publication.repoDID,
        record: value
      )
    else { throw WirePublicationQueryError.invalidResponse }
    return metadata
  }

  func resolveBlobURL(repoDID: String, cid: String) async throws -> String? {
    let trimmedCID = cid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCID.isEmpty, trimmedCID.count <= 512 else { return nil }
    let pdsBase = try await pdsBase(for: repoDID)
    guard !Self.isBridgyEndpoint(pdsBase) else { return nil }
    var components = URLComponents(string: "\(pdsBase)/xrpc/com.atproto.sync.getBlob")
    components?.queryItems = [
      URLQueryItem(name: "did", value: repoDID),
      URLQueryItem(name: "cid", value: trimmedCID),
    ]
    guard let blobURL = components?.url else { throw WirePublicationQueryError.invalidResponse }
    try await validateDNS(for: blobURL)
    return blobURL.absoluteString
  }

  private func pdsBase(for repoDID: String, asOf: Date = Date()) async throws -> String {
    if let cached = pdsEndpointCache[repoDID], cached.expiresAt > asOf {
      return cached.baseURL
    }
    pdsEndpointCache.removeValue(forKey: repoDID)
    if let task = pdsEndpointTasks[repoDID] { return try await task.value }
    let task = Task { try await self.fetchPDSBase(for: repoDID) }
    pdsEndpointTasks[repoDID] = task
    defer { pdsEndpointTasks.removeValue(forKey: repoDID) }
    let pdsBase = try await task.value
    if pdsEndpointCache.count >= 1_024 { pdsEndpointCache.removeAll(keepingCapacity: true) }
    pdsEndpointCache[repoDID] = CachedPDSEndpoint(
      baseURL: pdsBase,
      expiresAt: asOf.addingTimeInterval(600)
    )
    return pdsBase
  }

  private func fetchPDSBase(for repoDID: String) async throws -> String {
    guard let didURL = Self.didDocumentURL(for: repoDID, plcDirectoryBase: plcDirectoryBase)
    else { throw WirePublicationQueryError.invalidDID }
    try await validateDNS(for: didURL)
    let didDocument = try await jsonObject(at: didURL, maximumBytes: 64 * 1024)
    guard let services = didDocument?["service"] as? [[String: Any]] else {
      throw WirePublicationQueryError.invalidResponse
    }
    guard
      let rawEndpoint = services.lazy.compactMap({ service -> String? in
        let id = service["id"] as? String
        let type = service["type"] as? String
        guard id == "#atproto_pds" || type == "AtprotoPersonalDataServer" else { return nil }
        return service["serviceEndpoint"] as? String
      }).first
    else { throw WirePublicationQueryError.invalidResponse }
    guard let pdsBase = WirePublicEndpointValidator.validatedBase(rawEndpoint) else {
      throw WirePublicationQueryError.unsafeEndpoint
    }
    return pdsBase
  }

  private func validateDNS(for url: URL) async throws {
    guard let host = url.host, WirePublicEndpointValidator.isPublicHostname(host.lowercased())
    else {
      throw WirePublicationQueryError.unsafeEndpoint
    }
    try await dnsResolver.validatePublicAddresses(for: host)
  }

  private func jsonObject(at url: URL, maximumBytes: Int) async throws -> [String: Any]? {
    var request = HTTPClientRequest(url: url.absoluteString)
    request.headers.add(name: "Accept", value: "application/json")
    request.headers.add(name: "User-Agent", value: "TheSocialWire-WireWorker/1")
    let response = try await transport.execute(request, timeout: .seconds(10))
    if response.status == .notFound {
      await discard(response.body)
      return nil
    }
    if response.status == .tooManyRequests || response.status.code >= 500 {
      await discard(response.body)
      throw WirePublicationQueryError.transientStatus(response.status.code)
    }
    guard response.status == .ok else {
      await discard(response.body)
      throw WirePublicationQueryError.invalidResponse
    }
    let body: ByteBuffer
    do {
      body = try await response.body.collect(upTo: maximumBytes)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw WirePublicationQueryError.responseTooLarge
    }
    guard let object = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any]
    else { throw WirePublicationQueryError.invalidResponse }
    return object
  }

  private func discard(_ body: HTTPClientResponse.Body) async {
    _ = try? await body.collect(upTo: 16 * 1_024)
  }

  private static func didDocumentURL(for did: String, plcDirectoryBase: URL) -> URL? {
    if did.hasPrefix("did:plc:") {
      return plcDirectoryBase.appendingPathComponent(did)
    }
    guard did.hasPrefix("did:web:") else { return nil }
    let identifier = String(did.dropFirst("did:web:".count))
    let encodedParts = identifier.split(separator: ":", omittingEmptySubsequences: false)
    guard let encodedHost = encodedParts.first,
      let host = String(encodedHost).removingPercentEncoding?.lowercased(),
      WirePublicEndpointValidator.isPublicHostname(host)
    else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    let pathParts = encodedParts.dropFirst().compactMap { String($0).removingPercentEncoding }
    guard pathParts.count == encodedParts.count - 1,
      pathParts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\")
      })
    else { return nil }
    components.path =
      pathParts.isEmpty
      ? "/.well-known/did.json"
      : "/\(pathParts.joined(separator: "/"))/did.json"
    return components.url
  }

  private static func isBridgyEndpoint(_ pdsBase: String) -> Bool {
    guard let host = URL(string: pdsBase)?.host?.lowercased() else { return false }
    return host == "atproto.brid.gy" || host.hasSuffix(".brid.gy")
  }
}
