import AsyncHTTPClient
import GatewayCore
import Foundation
import GatewayCore
import Logging
import ThinAppViewCore

/// Follow-graph publication discovery aligned with web `discoverPublications`.
enum PublicationFollowDiscovery {
  private static let maxFollows = 500
  private static let followPageLimit = 100
  private static let discoveryBatchSize = 25

  static func discover(
    viewerDid: String,
    auth: AuthContext,
    repo: ATProtoAuthenticatedRepoClient,
    httpClient: HTTPClient,
    plcURL: String,
    logger: Logger
  ) async -> [ProjectionDiscoveredRow] {
    var subjectDids = Set<String>()
    subjectDids.insert(viewerDid)

    // Viewer repo graph.follow (canonical)
    do {
      var cursor: String?
      repeat {
        let page = try await repo.listRecords(
          auth: auth,
          repo: viewerDid,
          collection: PublicationLexicons.graphFollow,
          limit: followPageLimit,
          cursor: cursor,
          reverse: false
        )
        for record in page.records {
          if let subject = record.value.values["subject"] as? String {
            subjectDids.insert(subject)
          }
          if subjectDids.count >= maxFollows { break }
        }
        cursor = page.cursor
      } while cursor != nil && subjectDids.count < maxFollows
    } catch {
      logger.debug("Viewer graph.follow unreadable — merging relay")
    }

    // Bluesky relay getFollows
    if subjectDids.count < maxFollows {
      let relay = await fetchRelayFollows(viewerDid: viewerDid, httpClient: httpClient)
      for did in relay {
        subjectDids.insert(did)
        if subjectDids.count >= maxFollows { break }
      }
    }

    let subjects = Array(subjectDids.prefix(maxFollows))
    var discovered: [ProjectionDiscoveredRow] = []

    // Viewer own publications first
    if let own = await discoverAuthor(
      authorDid: viewerDid,
      handle: "You",
      displayName: "My Publications",
      avatar: nil,
      repo: repo,
      auth: auth,
      httpClient: httpClient,
      plcURL: plcURL
    ) {
      discovered.append(contentsOf: own)
    }

    let others = subjects.filter { $0 != viewerDid }
    var idx = 0
    while idx < others.count {
      let batch = Array(others[idx ..< min(idx + discoveryBatchSize, others.count)])
      await withTaskGroup(of: [ProjectionDiscoveredRow].self) { group in
        for did in batch {
          group.addTask {
            await discoverAuthor(
              authorDid: did,
              handle: did,
              displayName: nil,
              avatar: nil,
              repo: repo,
              auth: nil,
              httpClient: httpClient,
              plcURL: plcURL
            ) ?? []
          }
        }
        for await rows in group {
          discovered.append(contentsOf: rows)
        }
      }
      idx += discoveryBatchSize
    }

    // Dedupe by publicationId, sort by title
    var byId: [String: ProjectionDiscoveredRow] = [:]
    for row in discovered {
      byId[row.publicationId] = row
    }
    return byId.values.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  private static func discoverAuthor(
    authorDid: String,
    handle: String,
    displayName: String?,
    avatar: String?,
    repo: ATProtoAuthenticatedRepoClient,
    auth: AuthContext?,
    httpClient: HTTPClient,
    plcURL: String
  ) async -> [ProjectionDiscoveredRow]? {
    let now = Date()
    let pdsBase = try? await ATProtoPdsResolution.resolvePdsBase(
      repoDid: authorDid,
      plcBase: plcURL,
      httpClient: httpClient
    )

    for collection in PublicationLexicons.discoveryPublicationCollections {
      let page = try? await repo.listRecords(
        auth: auth,
        repo: authorDid,
        collection: collection,
        limit: 50,
        reverse: true
      )
      guard let records = page?.records, !records.isEmpty else { continue }

      return records.compactMap { record in
        let value = record.value.values
        let title =
          (value["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? displayName
          ?? handle
        let icon =
          RenderFieldExtractor.publicationIconUrl(from: value, repoDid: authorDid, pdsBase: pdsBase)
          ?? avatar.flatMap { RenderFieldExtractor.publicationIconUrl(from: ["avatar": $0], repoDid: authorDid, pdsBase: pdsBase) }
          ?? avatar
        return ProjectionDiscoveredRow(
          publicationId: record.uri,
          subscriptionPublicationId: record.uri,
          authorDid: authorDid,
          authorHandle: handle,
          title: title,
          iconUrl: icon,
          avatarUrl: avatar,
          discoveredAt: now
        )
      }
    }

    for collection in PublicationLexicons.discoveryContentCollections {
      let page = try? await repo.listRecords(
        auth: auth,
        repo: authorDid,
        collection: collection,
        limit: 1,
        reverse: true
      )
      if let records = page?.records, !records.isEmpty {
        return [
          ProjectionDiscoveredRow(
            publicationId: authorDid,
            subscriptionPublicationId: nil,
            authorDid: authorDid,
            authorHandle: handle,
            title: displayName ?? handle,
            iconUrl: avatar,
            avatarUrl: avatar,
            discoveredAt: now
          ),
        ]
      }
    }

    return nil
  }

  static func rowFromPublicationAtUri(
    atUri: String,
    repo: ATProtoAuthenticatedRepoClient,
    auth: AuthContext?,
    httpClient: HTTPClient,
    plcURL: String
  ) async -> ProjectionDiscoveredRow? {
    let normalized = PublicationProjectionLogic.normalizeAtRepoParam(atUri)
    guard let parsed = RenderFieldExtractor.parseAtUri(normalized),
          PublicationLexicons.publicationRecordCollections.contains(parsed.collection)
    else { return nil }

    guard let value = try? await repo.getRecordByAtUri(auth: auth, atUri: normalized) else {
      return nil
    }

    let dict = value.values
    let title =
      (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? parsed.rkey
    let pdsBase = try? await ATProtoPdsResolution.resolvePdsBase(
      repoDid: parsed.did,
      plcBase: plcURL,
      httpClient: httpClient
    )
    let icon =
      RenderFieldExtractor.publicationIconUrl(from: dict, repoDid: parsed.did, pdsBase: pdsBase)

    return ProjectionDiscoveredRow(
      publicationId: normalized,
      subscriptionPublicationId: normalized,
      authorDid: parsed.did,
      authorHandle: parsed.did,
      title: title,
      iconUrl: icon,
      avatarUrl: nil,
      discoveredAt: Date()
    )
  }

  private static func fetchRelayFollows(viewerDid: String, httpClient: HTTPClient) async -> [String] {
    var all: [String] = []
    var cursor: String?
    repeat {
      var comps = URLComponents(string: "\(ATProtoPdsResolution.bskyAppViewPublic)/xrpc/app.bsky.graph.getFollows")!
      var items = [
        URLQueryItem(name: "actor", value: viewerDid),
        URLQueryItem(name: "limit", value: "100"),
      ]
      if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
      comps.queryItems = items
      guard let url = comps.url?.absoluteString else { break }

      var request = HTTPClientRequest(url: url)
      request.headers.add(name: "Accept", value: "application/json")
      guard
        let response = try? await httpClient.execute(request, timeout: .seconds(15)),
        response.status == .ok,
        let body = try? await response.body.collect(upTo: 256 * 1024),
        let json = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any]
      else { break }

      let follows = (json["follows"] as? [[String: Any]]) ?? []
      all.append(contentsOf: follows.compactMap { $0["did"] as? String })
      cursor = json["cursor"] as? String
    } while cursor != nil && all.count < maxFollows
    return all
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
