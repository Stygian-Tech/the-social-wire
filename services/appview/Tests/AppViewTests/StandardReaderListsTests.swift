import Foundation
import Hummingbird
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Standard Reader lists")
struct StandardReaderListsTests {
  private let viewer = "did:plc:viewer"
  private let ownUri = "at://did:plc:viewer/app.standard-reader.list/own"
  private let publicUri = "at://did:plc:creator/app.standard-reader.list/public"
  private let publication = "at://did:plc:publisher/site.standard.publication/news"

  private func data(name: String = "News", publications: [String] = [], users: [String] = []) -> Data {
    try! JSONSerialization.data(withJSONObject: ["name": name, "publications": publications,
      "users": users, "createdAt": "2026-10-02T12:00:00Z"])
  }

  @Test("record identities reject wrong collections, malformed DIDs, and invalid keys")
  func identities() {
    #expect(StandardReaderListIdentity.parse(ownUri)?.did == viewer)
    for uri in ["https://standard-reader.app/list/example", "at://did:/app.standard-reader.list/key",
      "at://did:plc:viewer/site.standard.publication/key", ownUri + "?x=y", "at://did:plc:viewer/app.standard-reader.list/.."] {
      #expect(StandardReaderListIdentity.parse(uri) == nil)
    }
  }

  @Test("official share links resolve the canonical record without presentation state")
  func shareLinks() {
    let did = "did:plc:zu7vdjfbiijes5rjcaaqtzke"
    let key = "3mwwy7lufik34"
    let expected = "at://\(did)/app.standard-reader.list/\(key)"
    for input in [expected, "https://standard-reader.app/l/\(did)/\(key)",
      "https://standard-reader.app/l/did%3Aplc%3Azu7vdjfbiijes5rjcaaqtzke/\(key)?view=users#members"] {
      #expect(StandardReaderListIdentity.parseResolutionInput(input)?.uri == expected)
    }
    for input in ["http://standard-reader.app/l/\(did)/\(key)",
      "https://standard-reader.app.evil.test/l/\(did)/\(key)",
      "https://evil.test/l/\(did)/\(key)", "https://standard-reader.app:443/l/\(did)/\(key)",
      "https://viewer@standard-reader.app/l/\(did)/\(key)", "https://standard-reader.app/p/\(did)/\(key)",
      "https://standard-reader.app/l/viewer.test/\(key)", "https://standard-reader.app/l/did:/\(key)",
      "https://standard-reader.app/l/\(did)/", "https://standard-reader.app/l/\(did)/\(key)/extra",
      "https://standard-reader.app/l/\(did)/key%2Fextra", "https://standard-reader.app/l/\(did)/%252E%252E"] {
      #expect(StandardReaderListIdentity.parseResolutionInput(input) == nil)
    }
  }

  @Test("URL resolution returns canonical DID URI and uses public record lookup")
  func resolveShareLink() async throws {
    let service = StandardReaderListsService(reader: ListFixtureReader(own: [], saves: [],
      publicRecords: [publicUri: data(name: "Shared News")]))
    let list = try await service.resolve(input: "https://standard-reader.app/l/did:plc:creator/public?view=feed", viewerDid: viewer, prepareFeed: false)
    #expect(list.uri == publicUri)
    #expect(list.creatorDid == "did:plc:creator")
    #expect(list.name == "Shared News")
    #expect(!list.owned)
  }

  @Test("own lists and arbitrary-key saves merge once and retain ownership")
  func ownAndSaved() async throws {
    let records = [SemblePublicRecord(collection: StandardReaderListIdentity.collection,
      uri: ownUri, cid: nil, value: data(name: "My News", publications: [publication]))]
    let saveData = try JSONSerialization.data(withJSONObject: ["list": publicUri, "createdAt": "2026-10-02T12:00:00Z"])
    let saves = ["first", "arbitrary-other-key"].map {
      SemblePublicRecord(collection: StandardReaderListIdentity.saveCollection,
        uri: "at://\(viewer)/app.standard-reader.listSave/\($0)", cid: nil, value: saveData)
    }
    let service = StandardReaderListsService(reader: ListFixtureReader(own: records, saves: saves,
      publicRecords: [publicUri: data(name: "Public News", publications: [publication])]))
    let response = try await service.lists(viewerDid: viewer)
    #expect(response.complete)
    #expect(response.lists.map(\.uri) == [ownUri, publicUri])
    #expect(response.lists[0].owned && !response.lists[0].saved)
    #expect(response.lists[1].saved && !response.lists[1].owned)
  }

  @Test("a missing saved list does not discard valid own lists or claim completeness")
  func missingSave() async throws {
    let save = SemblePublicRecord(collection: StandardReaderListIdentity.saveCollection,
      uri: "at://\(viewer)/app.standard-reader.listSave/gone", cid: nil,
      value: try JSONSerialization.data(withJSONObject: ["list": publicUri]))
    let own = SemblePublicRecord(collection: StandardReaderListIdentity.collection, uri: ownUri, cid: nil, value: data())
    let response = try await StandardReaderListsService(reader: ListFixtureReader(own: [own], saves: [save], publicRecords: [:])).lists(viewerDid: viewer)
    #expect(response.lists.map(\.uri) == [ownUri])
    #expect(!response.complete)
  }

  @Test("creator search resolves the creator and marks viewer ownership")
  func creatorSearch() async throws {
    let own = SemblePublicRecord(collection: StandardReaderListIdentity.collection, uri: ownUri, cid: nil, value: data())
    let service = StandardReaderListsService(reader: ListFixtureReader(own: [own], saves: [], publicRecords: [:]))
    let response = try await service.search(creator: "viewer.test", viewerDid: viewer)
    #expect(response.lists.first?.owned == true)
    #expect(response.creatorDid == viewer)
    await #expect(throws: (any Error).self) { try await service.search(creator: "https://bad.example", viewerDid: viewer) }
  }

  @Test("creator search returns canonical identity when the creator has no public lists")
  func creatorWithoutLists() async throws {
    let service = StandardReaderListsService(reader: ListFixtureReader(own: [], saves: [], publicRecords: [:]))
    let result = try await service.search(creator: "viewer.test", viewerDid: viewer)
    #expect(result.creatorDid == viewer)
    #expect(result.lists.isEmpty && result.complete)
    let own = try await service.lists(viewerDid: viewer)
    #expect(own.creatorDid == nil)
  }

  @Test("strict list validation and ordered member deduplication")
  func records() {
    let identity = StandardReaderListIdentity.parse(ownUri)!
    let valid = StandardReaderListsService.decode(data(publications: [publication, publication], users: [viewer, viewer]), identity: identity, viewerDid: viewer, saved: false)
    #expect(valid?.publications == [publication])
    #expect(valid?.users == [viewer])
    #expect(StandardReaderListsService.decode(data(name: String(repeating: "x", count: 65)), identity: identity, viewerDid: viewer, saved: false) == nil)
    #expect(StandardReaderListsService.decode(data(publications: [ownUri]), identity: identity, viewerDid: viewer, saved: false) == nil)
    #expect(StandardReaderListsService.decode(data(users: ["not-a-did"]), identity: identity, viewerDid: viewer, saved: false) == nil)
  }

  @Test("author membership covers all of that author's publications without duplicates")
  func scopes() {
    let list = StandardReaderListDTO(uri: ownUri, name: "News", description: nil, creatorDid: viewer,
      publications: [publication], users: ["did:plc:publisher"], owned: true, saved: false)
    let scopes = StandardReaderListsService.scopes(list: list, viewerDid: viewer)
    #expect(scopes.count == 1)
    #expect(scopes[0].scopeKeys.isEmpty)
    #expect(AppViewUnreadCounterSupport.contentMatchesScope(authorDid: "did:plc:publisher", publicationSite: "another-publication", scope: scopes[0]))
    #expect(!AppViewUnreadCounterSupport.contentMatchesScope(authorDid: viewer, publicationSite: publication, scope: scopes[0]))
  }

  @Test("publication scopes match URI and resolved HTTPS site while excluding sibling publications")
  func publicationURLScopes() async {
    let list = StandardReaderListDTO(uri: ownUri, name: "News", description: nil, creatorDid: viewer,
      publications: [publication], users: [], owned: true, saved: false)
    let service = StandardReaderListsService(reader: ListFixtureReader(own: [], saves: [], publicRecords: [:]))
    let scopes = await service.resolvedScopes(list: list, viewerDid: viewer)
    #expect(scopes.count == 1)
    #expect(AppViewUnreadCounterSupport.contentMatchesScope(authorDid: "did:plc:publisher", publicationSite: publication, scope: scopes[0]))
    #expect(AppViewUnreadCounterSupport.contentMatchesScope(authorDid: "did:plc:publisher", publicationSite: "https://news.example", scope: scopes[0]))
    #expect(!AppViewUnreadCounterSupport.contentMatchesScope(authorDid: "did:plc:publisher", publicationSite: "https://other.example", scope: scopes[0]))
  }

  @Test("prepared public members enrich metadata without changing list membership")
  func publicationDetails() async throws {
    let missing = "at://did:plc:missing/site.standard.publication/gone"
    let record = SemblePublicRecord(collection: StandardReaderListIdentity.collection,
      uri: ownUri, cid: nil, value: data(publications: [publication, missing]))
    let service = StandardReaderListsService(reader: ListFixtureReader(own: [record], saves: [], publicRecords: [:]))
    let first = try await service.lists(viewerDid: viewer)
    _ = await service.resolvedScopes(list: first.lists[0], viewerDid: viewer)
    let enriched = try await service.lists(viewerDid: viewer)
    #expect(enriched.lists[0].publications == [publication, missing])
    #expect(enriched.lists[0].publicationDetails?.map(\.publicationId) == [publication])
    #expect(enriched.lists[0].publicationDetails?.first?.title == "Publication News")
    #expect(enriched.lists[0].publicationDetails?.first?.iconUrl == "https://news.example/icon.png")
    #expect(enriched.lists[0].publicationDetails?.first?.authorDid == "did:plc:publisher")
    let unresolved = StandardReaderListDTO(uri: ownUri, name: "News", description: nil, creatorDid: viewer,
      publications: [publication, missing], users: [], owned: true, saved: false)
    #expect(StandardReaderListCursor.fingerprint(viewerDid: viewer, list: unresolved, filter: "all") ==
      StandardReaderListCursor.fingerprint(viewerDid: viewer, list: enriched.lists[0], filter: "all"))
  }

  @Test("continuation rejects other viewers, filters, and changed list membership")
  func cursors() throws {
    let list = StandardReaderListDTO(uri: ownUri, name: "News", description: nil, creatorDid: viewer,
      publications: [publication], users: [], owned: true, saved: false)
    let fingerprint = StandardReaderListCursor.fingerprint(viewerDid: viewer, list: list, filter: "all")
    let cursor = StandardReaderListCursor.encode("underlying-position", fingerprint: fingerprint)
    #expect(try StandardReaderListCursor.decode(cursor, fingerprint: fingerprint) == "underlying-position")
    #expect(throws: (any Error).self) { try StandardReaderListCursor.decode(cursor, fingerprint: "other") }
    #expect(StandardReaderListCursor.fingerprint(viewerDid: "did:plc:other", list: list, filter: "all") != fingerprint)
    #expect(StandardReaderListCursor.fingerprint(viewerDid: viewer, list: list, filter: "unread") != fingerprint)
    #expect(try StandardReaderListCursor.decode(nil, fingerprint: fingerprint) == nil)
  }
}

private struct ListFixtureReader: StandardReaderListReading {
  let own: [SemblePublicRecord]
  let saves: [SemblePublicRecord]
  let publicRecords: [String: Data]
  func records(did: String, collection: String) async throws -> SemblePublicRecordRead {
    .init(records: collection == StandardReaderListIdentity.collection ? own : saves, complete: true)
  }
  func record(identity: StandardReaderListIdentity) async throws -> Data? { publicRecords[identity.uri] }
  func creatorDid(_ input: String) async throws -> String? { "did:plc:viewer" }
  func publicationSiteURL(_ uri: String) async throws -> String? { "https://news.example" }
  func publicationDetails(_ uri: String) async throws -> StandardReaderListPublicationRead? {
    guard !uri.contains("did:plc:missing") else { return nil }
    return .init(details: .init(publicationId: uri, title: "Publication News", authorDid: "did:plc:publisher",
      authorHandle: nil, iconUrl: "https://news.example/icon.png", avatarUrl: nil), siteURL: "https://news.example")
  }
}
