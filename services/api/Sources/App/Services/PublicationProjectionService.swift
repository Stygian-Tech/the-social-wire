import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import ThinAppViewCore

actor PublicationProjectionService {
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

  func sidebar(auth: AuthContext) async throws -> PublicationSidebarResponse {
    let viewerDid = auth.did
    let refreshedAt = Date()

    let folders = try await loadFolders(auth: auth)
    let prefs = try await loadPublicationPrefs(auth: auth)
    let subscriptionValues = try await loadGraphSubscriptions(auth: auth)
    let skyreaderRecords = try await loadSkyreaderSubscriptions(auth: auth)
    let discovered = await PublicationFollowDiscovery.discover(
      viewerDid: viewerDid,
      auth: auth,
      repo: repo,
      httpClient: httpClient,
      logger: logger
    )

    let rssRows = PublicationProjectionLogic.skyreaderRows(from: skyreaderRecords)
    let subscriptionKeys = PublicationProjectionLogic.subscriptionPublicationKeys(from: subscriptionValues)

    let existingForOrphans = discovered + rssRows
    let orphanUris = PublicationProjectionLogic.orphanGraphSubscriptionUris(
      subscriptions: subscriptionValues,
      existingRows: existingForOrphans
    )

    var graphOrphanRows: [ProjectionDiscoveredRow] = []
    for uri in orphanUris {
      if let row = await PublicationFollowDiscovery.rowFromPublicationAtUri(
        atUri: uri,
        repo: repo,
        auth: auth
      ) {
        graphOrphanRows.append(row)
      }
    }

    let visibleDiscovery = discovered + graphOrphanRows
    let segmented = PublicationProjectionLogic.segmentDiscovery(
      visibleDiscovery,
      viewerDid: viewerDid,
      subscriptionKeys: subscriptionKeys
    )

    let subscribed = PublicationProjectionLogic.mergeSubscribed(
      graphSubscribed: segmented.graphSubscribed,
      rssRows: rssRows,
      graphOrphanRows: graphOrphanRows
    )

    let myPublications = subscribed.filter {
      PublicationProjectionLogic.viewerOwnsPublication($0, viewerDid: viewerDid)
    }

    let prefsByPublicationId = Dictionary(
      uniqueKeysWithValues: prefs.map { ($0.publicationId, $0) }
    )

    let unfoldered = subscribed.filter { row in
      guard !PublicationProjectionLogic.viewerOwnsPublication(row, viewerDid: viewerDid) else {
        return false
      }
      let folderId = prefsByPublicationId[row.publicationId]?.value["folderId"]?.value as? String
      return folderId == nil || folderId?.isEmpty == true
    }

    let following = PublicationProjectionLogic.filterFollowingTab(
      followOwnedUnsubscribed: segmented.followOwnedUnsubscribed,
      myPublications: myPublications
    )

    let allRows = discovered + rssRows + graphOrphanRows
    let enrollAuthorDids = Array(Set(allRows.map(\.authorDid).filter { !$0.isEmpty })).sorted()

    let sidebarRows = try await mapRows(allRows, auth: auth)
    let myRows = try await mapRows(myPublications, auth: auth)
    let unfolderedRows = try await mapRows(unfoldered, auth: auth)
    let followingRows = try await mapRows(following, auth: auth)

    return PublicationSidebarResponse(
      viewerDid: viewerDid,
      folders: folders,
      publicationPrefs: prefs,
      allPublicationRows: sidebarRows,
      myPublications: myRows,
      subscribedUnfoldered: unfolderedRows,
      followingTabPublications: followingRows,
      enrollAuthorDids: enrollAuthorDids,
      refreshedAt: refreshedAt
    )
  }

  // MARK: - PDS loaders

  private func loadFolders(auth: AuthContext) async throws -> [PublicationFolderRecord] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.folder,
      maxPages: 10
    )
    return records.map { record in
      let rkey = rkeyFromUri(record.uri) ?? record.uri
      return PublicationFolderRecord(
        uri: record.uri,
        rkey: rkey,
        value: record.value.values.mapValues { AnyCodable($0) }
      )
    }
  }

  private func loadPublicationPrefs(auth: AuthContext) async throws -> [PublicationPrefsRecordDTO] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.publicationPrefs,
      maxPages: 20
    )
    return records.compactMap { record in
      guard let publicationId = record.value.values["publicationId"] as? String else { return nil }
      return PublicationPrefsRecordDTO(
        uri: record.uri,
        publicationId: publicationId,
        value: record.value.values.mapValues { AnyCodable($0) }
      )
    }
  }

  private func loadGraphSubscriptions(auth: AuthContext) async throws -> [[String: Any]] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.graphSubscription,
      maxPages: 20
    )
    return records.map(\.value.values)
  }

  private func loadSkyreaderSubscriptions(auth: AuthContext) async throws -> [(uri: String, value: PdsRecordJSON)] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.skyreaderFeedSubscription,
      maxPages: 20
    )
    return records.map { ($0.uri, $0.value) }
  }

  private func mapRows(
    _ rows: [ProjectionDiscoveredRow],
    auth: AuthContext
  ) async throws -> [SidebarPublicationRow] {
    var out: [SidebarPublicationRow] = []
    for row in rows {
      let scope = await buildAppViewScope(
        publicationId: row.publicationId,
        authorDid: row.authorDid,
        auth: auth
      )
      out.append(
        SidebarPublicationRow(
          publicationId: row.publicationId,
          subscriptionPublicationId: row.subscriptionPublicationId,
          authorDid: row.authorDid,
          authorHandle: row.authorHandle,
          title: row.title,
          iconUrl: row.iconUrl,
          avatarUrl: row.avatarUrl,
          discoveredAt: row.discoveredAt,
          appViewScope: scope
        )
      )
    }
    return out
  }

  private func rkeyFromUri(_ uri: String) -> String? {
    guard let parsed = RenderFieldExtractor.parseAtUri(uri) else { return nil }
    return parsed.rkey
  }

  private func buildAppViewScope(
    publicationId: String,
    authorDid: String,
    auth: AuthContext
  ) async -> PublicationAppViewScope {
    let normalized = PublicationProjectionLogic.normalizeAtRepoParam(publicationId)

    if normalized.hasPrefix(PublicationLexicons.rssPublicationPrefix) {
      return PublicationAppViewScope(
        authorDid: PublicationLexicons.rssAuthorDid,
        publicationAtUri: nil,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      )
    }

    if normalized.hasPrefix("did:") {
      return PublicationAppViewScope(
        authorDid: normalized,
        publicationAtUri: nil,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      )
    }

    guard let parsed = RenderFieldExtractor.parseAtUri(normalized) else {
      return PublicationAppViewScope(
        authorDid: authorDid,
        publicationAtUri: nil,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      )
    }

    var atUriKeys = RenderFieldExtractor.publicationFilterEquivalenceKeys(publicationAtUri: normalized)
    var siteUrlKeys = Set<String>()

    if let value = try? await repo.getRecordByAtUri(auth: auth, atUri: normalized) {
      for url in publicationSiteUrlsFromRecord(value.values) {
        siteUrlKeys.insert(url)
      }
      await mergeSiblingPublicationScopeKeys(
        authorDid: parsed.did,
        recordValue: value.values,
        atUriKeys: &atUriKeys,
        siteUrlKeys: &siteUrlKeys,
        auth: auth
      )
    }

    return PublicationAppViewScope(
      authorDid: parsed.did,
      publicationAtUri: normalized,
      publicationScopeAtUris: Array(atUriKeys).sorted(),
      publicationSiteUrls: Array(siteUrlKeys).sorted()
    )
  }

  private func publicationSiteUrlsFromRecord(_ value: [String: Any]) -> [String] {
    var urls: [String] = []
    for key in ["url", "siteUrl", "site", "homepage"] {
      if let raw = value[key] as? String,
         let norm = RenderFieldExtractor.normalizePublicationSiteUrl(raw)
      {
        urls.append(norm)
      }
    }
    return urls
  }

  private func mergeSiblingPublicationScopeKeys(
    authorDid: String,
    recordValue: [String: Any],
    atUriKeys: inout Set<String>,
    siteUrlKeys: inout Set<String>,
    auth: AuthContext
  ) async {
    let siteNorm = (recordValue["site"] as? String).flatMap {
      RenderFieldExtractor.normalizePublicationSiteUrl($0)
    }
    guard let siteNorm else { return }

    for collection in PublicationLexicons.discoveryPublicationCollections {
      let page = try? await repo.listRecords(
        auth: auth,
        repo: authorDid,
        collection: collection,
        limit: 50,
        reverse: true
      )
      guard let records = page?.records else { continue }
      for record in records {
        let site = (record.value.values["site"] as? String).flatMap {
          RenderFieldExtractor.normalizePublicationSiteUrl($0)
        }
        guard site == siteNorm else { continue }
        atUriKeys.formUnion(RenderFieldExtractor.publicationFilterEquivalenceKeys(publicationAtUri: record.uri))
        for url in publicationSiteUrlsFromRecord(record.value.values) {
          siteUrlKeys.insert(url)
        }
      }
    }
  }
}
