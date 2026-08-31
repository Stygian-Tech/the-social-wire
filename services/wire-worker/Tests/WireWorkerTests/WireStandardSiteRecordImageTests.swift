import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Standard Site record images")
struct WireStandardSiteRecordImageTests {
  @Test("extracts the canonical coverImage blob from the real fixture")
  func canonicalCoverImageBlob() throws {
    let record = try fixture("site-standard-document")

    #expect(WireStandardSiteRecordImage.blobCID(from: record) == "bafycover")
  }

  @Test("prefers direct cover and thumbnail fields before metadata fallbacks")
  func directCandidateOrder() {
    #expect(
      WireStandardSiteRecordImage.directURL(from: [
        "coverImage": "https://record.publisher.social/cover.png",
        "thumbnailUrl": "https://record.publisher.social/thumbnail.png",
      ]) == "https://record.publisher.social/cover.png"
    )
    #expect(
      WireStandardSiteRecordImage.directURL(from: [
        "coverImage": ["ref": ["$link": "bafycover"]],
        "thumbnailUrl": "https://record.publisher.social/thumbnail.png",
      ]) == "https://record.publisher.social/thumbnail.png"
    )
  }

  @Test("rejects non-HTTP direct values and malformed blob references")
  func rejectsMalformedCandidates() {
    #expect(WireStandardSiteRecordImage.directURL(from: ["image": "at://did/image/one"]) == nil)
    #expect(WireStandardSiteRecordImage.directURL(from: ["image": "http://127.0.0.1/a"]) == nil)
    #expect(WireStandardSiteRecordImage.directURL(from: ["image": "https://router.local/a"]) == nil)
    #expect(
      WireStandardSiteRecordImage.directURL(from: [
        "image": "https://user:password@record.publisher.social/a"
      ]) == nil
    )
    #expect(WireStandardSiteRecordImage.blobCID(from: ["coverImage": ["ref": [:]]]) == nil)
  }

  @Test("prefers a direct record image without requiring blob hosting")
  func prefersDirectRecordImage() async throws {
    let resolver = StubWireBlobURLResolver(
      result: "https://pds.publisher.social/xrpc/com.atproto.sync.getBlob?did=author&cid=cover"
    )

    let resolved = try await WireStandardSiteRecordImage.resolveURL(
      from: [
        "coverImage": ["ref": ["$link": "bafycover"]],
        "thumbnailUrl": "http://record.publisher.social/image.png",
      ],
      repoDID: "did:plc:author",
      blobURLResolver: resolver
    )

    #expect(resolved == "https://record.publisher.social/image.png")
    #expect(await resolver.requests.isEmpty)
  }

  @Test("resolves a blob when the record has no direct image")
  func resolvesBlobWithoutDirectImage() async throws {
    let resolver = StubWireBlobURLResolver(
      result: "https://pds.publisher.social/xrpc/com.atproto.sync.getBlob?did=author&cid=cover"
    )
    let resolved = try await WireStandardSiteRecordImage.resolveURL(
      from: ["coverImage": ["ref": ["$link": "bafycover"]]],
      repoDID: "did:plc:author",
      blobURLResolver: resolver
    )

    #expect(resolved?.contains("sync.getBlob") == true)
    let requests = await resolver.requests
    #expect(requests.count == 1)
    #expect(requests.first?.0 == "did:plc:author")
    #expect(requests.first?.1 == "bafycover")
  }

  @Test("blob lookup failures never block an otherwise valid article")
  func blobLookupFailuresAreOptional() async throws {
    for failure in [
      WirePublicationQueryError.dnsUnavailable,
      WirePublicationQueryError.transientStatus(429),
      WirePublicationQueryError.invalidResponse,
    ] {
      let resolved = try await WireStandardSiteRecordImage.resolveURL(
        from: ["coverImage": ["ref": ["$link": "bafycover"]]],
        repoDID: "did:plc:author",
        blobURLResolver: StubWireBlobURLResolver(error: failure)
      )
      #expect(resolved == nil)
    }
  }

  private func fixture(_ name: String) throws -> [String: Any] {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

private actor StubWireBlobURLResolver: WireBlobURLResolving {
  let result: String?
  let error: (any Error & Sendable)?
  private(set) var requests: [(String, String)] = []

  init(result: String?) {
    self.result = result
    self.error = nil
  }

  init(error: any Error & Sendable) {
    self.result = nil
    self.error = error
  }

  func resolveBlobURL(repoDID: String, cid: String) throws -> String? {
    requests.append((repoDID, cid))
    if let error { throw error }
    return result
  }
}
