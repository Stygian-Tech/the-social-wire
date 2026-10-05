import AsyncHTTPClient
import Foundation
import GatewayCore
import NIOCore
import ThinAppViewCore

protocol StandardReaderListReading: Sendable {
  func records(did: String, collection: String) async throws -> SemblePublicRecordRead
  func record(identity: StandardReaderListIdentity) async throws -> Data?
  func publicationSiteURL(_ uri: String) async throws -> String?
  func publicationDetails(_ uri: String) async throws -> StandardReaderListPublicationRead?
  func creatorDid(_ input: String) async throws -> String?
}

struct ATProtoStandardReaderListReader: StandardReaderListReading {
  let repo: ATProtoAuthenticatedRepoClient
  let httpClient: HTTPClient
  let plcURL: String

  func records(did: String, collection: String) async throws -> SemblePublicRecordRead {
    try await ATProtoSemblePublicRecordReader(repo: repo).read(repoDid: did, collections: [collection])
  }

  func record(identity: StandardReaderListIdentity) async throws -> Data? {
    guard let value = try await repo.getRecord(
      auth: nil, repo: identity.did, collection: StandardReaderListIdentity.collection, rkey: identity.rkey
    ) else { return nil }
    return try JSONSerialization.data(withJSONObject: value.values)
  }

  func publicationSiteURL(_ uri: String) async throws -> String? {
    try await publicationDetails(uri)?.siteURL
  }

  func publicationDetails(_ uri: String) async throws -> StandardReaderListPublicationRead? {
    guard let identity = SembleAtUri.parse(uri), identity.collection == "site.standard.publication",
      let pds = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: identity.did, plcBase: plcURL, httpClient: httpClient, timeout: .seconds(1)),
      var components = URLComponents(string: "\(pds)/xrpc/com.atproto.repo.getRecord") else { return nil }
    components.queryItems = [URLQueryItem(name: "repo", value: identity.did),
      URLQueryItem(name: "collection", value: identity.collection), URLQueryItem(name: "rkey", value: identity.rkey)]
    guard let url = components.url?.absoluteString else { return nil }
    let response = try await httpClient.execute(HTTPClientRequest(url: url), timeout: .seconds(1))
    guard response.status == .ok else { return nil }
    let body = try await response.body.collect(upTo: 256 * 1024)
    guard let object = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let record = object["value"] as? [String: Any] else { return nil }
    let title = [record["name"] as? String, record["title"] as? String].compactMap { value in
      value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.first { !$0.isEmpty } ?? identity.rkey
    let icon = RenderFieldExtractor.publicationIconUrl(from: record, repoDid: identity.did, pdsBase: pds)
    let site = (record["url"] as? String).flatMap { value -> String? in
      guard let parsed = URLComponents(string: value), parsed.scheme == "https", parsed.host != nil,
        parsed.user == nil, parsed.password == nil else { return nil }
      return value
    }
    return StandardReaderListPublicationRead(details: StandardReaderListPublicationDTO(
      publicationId: uri, title: title, authorDid: identity.did, authorHandle: nil, iconUrl: icon, avatarUrl: nil), siteURL: site)
  }

  func creatorDid(_ input: String) async throws -> String? {
    try await ATProtoPdsResolution.resolveRepoDid(handleOrDid: input, httpClient: httpClient)
  }
}

extension StandardReaderListReading {
  func publicationSiteURL(_ uri: String) async throws -> String? { nil }
  func publicationDetails(_ uri: String) async throws -> StandardReaderListPublicationRead? {
    StandardReaderListPublicationRead(details: nil, siteURL: try await publicationSiteURL(uri))
  }
}
