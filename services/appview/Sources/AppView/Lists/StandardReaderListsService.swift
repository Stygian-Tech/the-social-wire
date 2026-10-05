import Crypto
import Foundation
import GatewayCore
import Hummingbird
import ThinAppViewCore

actor StandardReaderListsService {
  let reader: any StandardReaderListReading
  private let preparationLimiter = StandardReaderPreparationLimiter()
  let enrollment = StandardReaderListEnrollment()
  private var cache: [String: (expiresAt: Date, response: StandardReaderListsResponse)] = [:]
  private var inFlight: [String: (revision: Int, task: Task<StandardReaderListsResponse, Error>)] = [:]
  private var revisions: [String: Int] = [:]
  private var prepared: [String: (list: StandardReaderListDTO, scopes: [AppViewPublicationScope], expiresAt: Date)] = [:]
  private var preparation: [String: Task<Void, Never>] = [:]
  private var missingUntil: [String: Date] = [:]
  private var preparationRevision: [String: Int] = [:]
  private var siteCacheRevision = 0
  private var siteURLCache: [String: (url: String?, expiresAt: Date)] = [:]
  private var publicationDetailsCache: [String: StandardReaderListPublicationDTO] = [:]
  private let publicationProjection: PublicationProjectionService?

  init(reader: any StandardReaderListReading, publicationProjection: PublicationProjectionService? = nil) {
    self.reader = reader
    self.publicationProjection = publicationProjection
  }

  func lists(viewerDid: String, refresh: Bool = false) async throws -> StandardReaderListsResponse {
    if refresh {
      siteCacheRevision += 1
      siteURLCache.removeAll()
      publicationDetailsCache.removeAll()
      let prefix = viewerDid + "\n"
      missingUntil = missingUntil.filter { !$0.key.hasPrefix(prefix) }
      for key in prepared.keys.filter({ $0.hasPrefix(prefix) }) { prepared[key] = nil }
      for key in preparation.keys.filter({ $0.hasPrefix(prefix) }) {
        preparationRevision[key, default: 0] += 1
        preparation[key]?.cancel()
        preparation[key] = nil
      }
    }
    if !refresh, let cached = cache[viewerDid], cached.expiresAt > Date() { return await enriched(cached.response, viewerDid: viewerDid) }
    if !refresh, let load = inFlight[viewerDid] { return await enriched(try await load.task.value, viewerDid: viewerDid) }
    let revision = (revisions[viewerDid] ?? 0) + 1
    revisions[viewerDid] = revision
    let task = Task { try await self.loadLists(viewerDid: viewerDid) }
    inFlight[viewerDid] = (revision, task)
    defer { if inFlight[viewerDid]?.revision == revision { inFlight[viewerDid] = nil } }
    let response = try await task.value
    if revisions[viewerDid] == revision {
      cache[viewerDid] = (Date().addingTimeInterval(60), response)
      for list in response.lists { prepare(list: list, viewerDid: viewerDid) }
    }
    if cache.count > 200 {
      cache = cache.filter { $0.value.expiresAt > Date() }
      if cache.count > 200, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
        cache[oldest] = nil
      }
    }
    return await enriched(response, viewerDid: viewerDid)
  }

  private func loadLists(viewerDid: String) async throws -> StandardReaderListsResponse {
    async let ownRead = reader.records(did: viewerDid, collection: StandardReaderListIdentity.collection)
    async let saveRead = reader.records(did: viewerDid, collection: StandardReaderListIdentity.saveCollection)
    let (own, saves) = try await (ownRead, saveRead)
    var byUri: [String: StandardReaderListDTO] = [:]
    let savedUris = Set(saves.records.compactMap { record -> String? in
      guard let value = try? JSONSerialization.jsonObject(with: record.value) as? [String: Any],
        let uri = value["list"] as? String, StandardReaderListIdentity.parse(uri) != nil else { return nil }
      return uri
    })
    for record in own.records {
      guard let identity = StandardReaderListIdentity.parse(record.uri), identity.did == viewerDid,
        let list = Self.decode(record.value, identity: identity, viewerDid: viewerDid, saved: savedUris.contains(identity.uri))
      else { continue }
      byUri[list.uri] = list
    }
    // Bound fan-out and preserve valid rows when a saved public record is gone or temporarily unavailable.
    var complete = own.complete && saves.complete && savedUris.count <= 200
    let unresolved = savedUris.filter { byUri[$0] == nil }.sorted().prefix(200)
    for batchStart in stride(from: 0, to: unresolved.count, by: 5) {
      let batch = Array(unresolved.dropFirst(batchStart).prefix(5))
      let resolved = await withTaskGroup(of: StandardReaderListDTO?.self) { group in
        for uri in batch {
          group.addTask { try? await self.resolve(input: uri, viewerDid: viewerDid, saved: true, prepareFeed: false) }
        }
        var result: [StandardReaderListDTO] = []
        for await list in group { if let list { result.append(list) } }
        return result
      }
      if resolved.count != batch.count { complete = false }
      for list in resolved { byUri[list.uri] = list }
    }
    return Self.response(Array(byUri.values), complete: complete)
  }

  func search(creator: String, viewerDid: String) async throws -> StandardReaderListsResponse {
    let input = creator.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, input.count <= 253, !input.contains("/"), !input.contains("?") else {
      throw HTTPError(.badRequest, message: "Enter a creator handle or DID.")
    }
    guard let did = try await reader.creatorDid(input) else {
      throw HTTPError(.notFound, message: "Creator could not be resolved.")
    }
    let records = try await reader.records(did: did, collection: StandardReaderListIdentity.collection)
    let saved = Set((try await lists(viewerDid: viewerDid)).lists.filter(\.saved).map(\.uri))
    var response = Self.response(records.records.compactMap {
      guard let identity = StandardReaderListIdentity.parse($0.uri), identity.did == did else { return nil }
      return Self.decode($0.value, identity: identity, viewerDid: viewerDid, saved: saved.contains(identity.uri))
    }, complete: records.complete)
    response.creatorDid = did
    return await enriched(response, viewerDid: viewerDid)
  }

  func resolve(input: String, viewerDid: String, saved: Bool = false, prepareFeed: Bool = true) async throws -> StandardReaderListDTO {
    guard let identity = StandardReaderListIdentity.parseResolutionInput(input) else {
      throw HTTPError(.badRequest, message: "Enter a Standard Reader list URL or an app.standard-reader.list AT URI.")
    }
    guard let data = try await reader.record(identity: identity),
      let list = Self.decode(data, identity: identity, viewerDid: viewerDid, saved: saved) else {
      throw HTTPError(.notFound, message: "List was not found or its record is invalid.")
    }
    if prepareFeed { prepare(list: list, viewerDid: viewerDid) }
    return await enriched(list, viewerDid: viewerDid)
  }

  private func prepare(list: StandardReaderListDTO, viewerDid: String) {
    let key = viewerDid + "\n" + list.uri
    missingUntil[key] = nil
    let revision = (preparationRevision[key] ?? 0) + 1
    preparationRevision[key] = revision
    preparation[key]?.cancel()
    preparation[key] = Task {
      await self.preparationLimiter.acquire()
      guard !Task.isCancelled else { await self.preparationLimiter.release(); return }
      let scopes = await self.resolvedScopes(list: list, viewerDid: viewerDid)
      await self.preparationLimiter.release()
      guard !Task.isCancelled, self.preparationRevision[key] == revision else { return }
      self.prepared[key] = (list, scopes, Date().addingTimeInterval(60))
      if self.prepared.count > 1000 {
        self.prepared = self.prepared.filter { $0.value.expiresAt > Date() }
        if self.prepared.count > 1000,
           let oldest = self.prepared.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
          self.prepared[oldest] = nil
        }
      }
      self.preparation[key] = nil
    }
  }

  func preparedFeed(input: String, viewerDid: String) throws -> (list: StandardReaderListDTO, scopes: [AppViewPublicationScope]) {
    guard let identity = StandardReaderListIdentity.parse(input) else {
      throw HTTPError(.badRequest, message: "Enter a canonical Standard Reader list AT URI.")
    }
    let key = viewerDid + "\n" + identity.uri
    if let until = missingUntil[key], until > Date() {
      throw HTTPError(.notFound, message: "The public list was not found.")
    }
    if let snapshot = prepared[key], snapshot.expiresAt > Date() { return (snapshot.list, snapshot.scopes) }
    if preparation[key] == nil {
      preparation[key] = Task {
        do { _ = try await self.resolve(input: identity.uri, viewerDid: viewerDid) }
        catch {
          if let error = error as? HTTPError, error.status == .notFound {
            self.missingUntil[key] = Date().addingTimeInterval(60)
          }
          self.preparation[key] = nil
        }
      }
    }
    throw HTTPError(.serviceUnavailable, message: "The list projection is warming. Refresh to retry.")
  }

  static func decode(_ data: Data, identity: StandardReaderListIdentity, viewerDid: String, saved: Bool) -> StandardReaderListDTO? {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name.count <= 64, name.utf8.count <= 640,
      let createdAt = value["createdAt"] as? String, parseDate(createdAt) != nil,
      let publications = value["publications"] as? [String], publications.count <= 500,
      publications.allSatisfy({ publicationIdentity($0) != nil })
    else { return nil }
    let users: [String]
    if let rawUsers = value["users"] {
      guard let valid = rawUsers as? [String], valid.count <= 500,
        valid.allSatisfy({ $0.hasPrefix("did:") && !$0.contains("/") && !$0.contains(where: \.isWhitespace) }) else { return nil }
      users = valid
    } else { users = [] }
    let description = value["description"] as? String
    guard description == nil || (description!.count <= 300 && description!.utf8.count <= 3000) else { return nil }
    return StandardReaderListDTO(uri: identity.uri, name: name, description: description,
      creatorDid: identity.did, publications: unique(publications), users: unique(users), owned: identity.did == viewerDid, saved: saved)
  }

  static func publicationIdentity(_ uri: String) -> (did: String, uri: String)? {
    guard let parsed = SembleAtUri.parse(uri), parsed.collection == "site.standard.publication",
      !uri.contains("?"), !uri.contains("#"), !uri.contains(where: \.isWhitespace) else { return nil }
    return (parsed.did, uri)
  }

  func resolvedScopes(list: StandardReaderListDTO, viewerDid: String) async -> [AppViewPublicationScope] {
    let cacheRevision = siteCacheRevision
    let missing = list.publications.filter { siteURLCache[$0]?.expiresAt ?? .distantPast <= Date() }
    for start in stride(from: 0, to: missing.count, by: 5) {
      let batch = Array(missing.dropFirst(start).prefix(5))
      let values = await withTaskGroup(of: (String, String?, StandardReaderListPublicationDTO?).self) { group in
        for uri in batch {
          group.addTask {
            if let publication = try? await self.reader.publicationDetails(uri) {
              return (uri, publication.siteURL, publication.details)
            }
            return (uri, nil, nil)
          }
        }
        var values: [(String, String?, StandardReaderListPublicationDTO?)] = []
        for await value in group { values.append(value) }
        return values
      }
      for (uri, url, details) in values where siteCacheRevision == cacheRevision {
        siteURLCache[uri] = (url, Date().addingTimeInterval(url == nil ? 60 : 3600))
        if let details { publicationDetailsCache[uri] = details }
      }
    }
    if siteURLCache.count > 2000 { siteURLCache = siteURLCache.filter { $0.value.expiresAt > Date() } }
    publicationDetailsCache = publicationDetailsCache.filter { siteURLCache[$0.key] != nil }
    return Self.scopes(list: list, viewerDid: viewerDid).map { scope in
      let urls = scope.publicationAtUri.flatMap { siteURLCache[$0]?.url }.map { [$0] } ?? []
      return AppViewPublicationScope(viewerDid: scope.viewerDid, publicationId: scope.publicationId,
        authorDid: scope.authorDid, publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris, publicationSiteUrls: urls,
        scopeKeys: AppViewUnreadCounterSupport.scopeKeys(publicationAtUri: scope.publicationAtUri,
          publicationScopeAtUris: scope.publicationScopeAtUris, publicationSiteUrls: urls),
        sectionKeys: [], updatedAt: scope.updatedAt)
    }
  }

  private func enriched(_ response: StandardReaderListsResponse, viewerDid: String) async -> StandardReaderListsResponse {
    var lists: [StandardReaderListDTO] = []
    for list in response.lists { lists.append(await enriched(list, viewerDid: viewerDid)) }
    var result = StandardReaderListsResponse(lists: lists, refreshedAt: response.refreshedAt, complete: response.complete)
    result.creatorDid = response.creatorDid
    return result
  }

  private func enriched(_ list: StandardReaderListDTO, viewerDid: String) async -> StandardReaderListDTO {
    let rows = await publicationProjection?.sidebarRows(for: viewerDid, publicationIds: list.publications) ?? []
    var byId: [String: StandardReaderListPublicationDTO] = [:]
    for uri in list.publications {
      if let detail = publicationDetailsCache[uri], siteURLCache[uri]?.expiresAt ?? .distantPast > Date() {
        byId[uri] = detail
      }
      guard let row = rows.first(where: { PublicationProjectionLogic.publicationIdsMatch($0.publicationId, uri) }) else { continue }
      byId[uri] = StandardReaderListPublicationDTO(publicationId: uri,
        title: row.title, authorDid: row.authorDid, authorHandle: row.authorHandle,
        iconUrl: row.iconUrl, avatarUrl: row.avatarUrl)
    }
    var result = list
    result.publicationDetails = list.publications.compactMap { byId[$0] }
    return result
  }

  static func scopes(list: StandardReaderListDTO, viewerDid: String) -> [AppViewPublicationScope] {
    let now = Date()
    let authorOnly = Set(list.users)
    var scopes = list.users.map {
      AppViewPublicationScope(viewerDid: viewerDid, publicationId: $0, authorDid: $0,
        publicationAtUri: nil, publicationScopeAtUris: [], publicationSiteUrls: [], scopeKeys: [], sectionKeys: [], updatedAt: now)
    }
    scopes += list.publications.compactMap { uri in
      guard let identity = publicationIdentity(uri), !authorOnly.contains(identity.did) else { return nil }
      return AppViewPublicationScope(viewerDid: viewerDid, publicationId: uri, authorDid: identity.did,
        publicationAtUri: uri, publicationScopeAtUris: [uri], publicationSiteUrls: [], scopeKeys: [uri], sectionKeys: [], updatedAt: now)
    }
    return scopes
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func response(_ lists: [StandardReaderListDTO], complete: Bool) -> StandardReaderListsResponse {
    StandardReaderListsResponse(lists: lists.sorted {
      if $0.owned != $1.owned { return $0.owned }
      let compare = $0.name.localizedStandardCompare($1.name)
      return compare == .orderedSame ? $0.uri < $1.uri : compare == .orderedAscending
    }, refreshedAt: ISO8601DateFormatter().string(from: Date()), complete: complete)
  }
}
