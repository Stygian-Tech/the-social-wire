import Foundation
import GatewayCore
import Hummingbird
import Logging
import NIOCore
import ThinAppViewCore

struct BootstrapStreamService {
  let projectionService: PublicationProjectionService
  let readService: ThinAppViewReadService
  let enrollService: ThinAppViewEnrollService
  let skyreaderIngestionService: ThinAppViewSkyreaderIngestionService
  let projectionCache: (any AppViewProjectionCacheStore)?
  let logger: Logger

  func writeStream(auth: AuthContext, writer: inout any ResponseBodyWriter) async throws {
    let streamStarted = Date()
    let refreshedAt = Date()
    do {
      if let cached = try await loadFreshCachedSnapshot(viewerDid: auth.did) {
        try await emitCachedBootstrap(
          auth: auth,
          snapshot: cached,
          refreshedAt: refreshedAt,
          writer: &writer
        )
        scheduleBackgroundWarmers(
          auth: auth,
          priority: cached.priority,
          enrollAuthorDids: cached.priority.enrollAuthorDids
        )
        scheduleBackgroundRefresh(auth: auth, priority: cached.priority)
        BootstrapStreamTimings.logPhase(
          logger,
          phase: "totalCached",
          startedAt: streamStarted,
          viewerDid: auth.did
        )
        try await writer.finish(nil)
        return
      }

      let priorityStarted = Date()
      let priority = try await projectionService.bootstrapPrioritySidebar(auth: auth)
      try await writeEvent(.sidebarPriority(priority.response), writer: &writer)
      BootstrapStreamTimings.logPhase(
        logger,
        phase: "prioritySidebar",
        startedAt: priorityStarted,
        viewerDid: auth.did
      )

      let unreadStarted = Date()
      let unreadRows = priority.response.allPublicationRows
        + priority.response.myPublications
        + priority.response.subscribedUnfoldered
        + priority.response.followingTabPublications
      var unreadCounts = await projectionService.unreadCountsMap(for: unreadRows)
      if unreadCounts.isEmpty,
         let cachedCounts = try await projectionCache?.cachedUnreadCounts(viewerDid: auth.did)
      {
        unreadCounts = cachedCounts
      }
      try await writeEvent(.unreadCounts(unreadCounts), writer: &writer)
      BootstrapStreamTimings.logPhase(
        logger,
        phase: "unreadCounts",
        startedAt: unreadStarted,
        viewerDid: auth.did,
        extra: ["publicationCount": "\(unreadCounts.count)"]
      )

      let foldersStarted = Date()
      let folders = try await projectionService.bootstrapFolderSidebar(
        auth: auth,
        context: priority.context
      )
      try await writeEvent(.sidebarFolders(folders), writer: &writer)
      BootstrapStreamTimings.logPhase(
        logger,
        phase: "folderSidebar",
        startedAt: foldersStarted,
        viewerDid: auth.did
      )

      let selectedId = BootstrapStreamSelection.firstUnreadPublicationId(
        myPublications: priority.response.myPublications,
        subscribedUnfoldered: priority.response.subscribedUnfoldered,
        following: priority.response.followingTabPublications,
        unreadCounts: unreadCounts
      )

      if let selectedId {
        try await writeEvent(.selectedPublication(publicationId: selectedId), writer: &writer)
        if let row = BootstrapStreamSelection.row(publicationId: selectedId, in: priority.response) {
          let entriesStarted = Date()
          if let page = try await readService.cachedOrListedFirstPage(
            auth: auth,
            publicationId: selectedId,
            scope: row.appViewScope,
            limit: 50
          ) {
            let payload = AppViewBootstrapEntriesPagePayload(
              publicationId: selectedId,
              entries: page.entries.map(Self.bootstrapEntry),
              cursor: page.cursor
            )
            try await writeEvent(.entriesPage(payload), writer: &writer)
          } else {
            try await writeEvent(
              .warning("Could not load first feed page for \(selectedId)."),
              writer: &writer
            )
          }
          BootstrapStreamTimings.logPhase(
            logger,
            phase: "selectedEntryPage",
            startedAt: entriesStarted,
            viewerDid: auth.did,
            extra: ["publicationId": selectedId]
          )

          scheduleSelectedPublicationWarmers(
            auth: auth,
            row: row,
            priorityAuthorDids: BootstrapStreamSelection.priorityAuthorDids(from: priority.response)
          )
        }
      }

      try await writeEvent(.done(refreshedAt: refreshedAt), writer: &writer)

      let cacheExpires = Date().addingTimeInterval(AppViewProjectionCacheTTL.sidebarSeconds)
      let unreadExpires = Date().addingTimeInterval(AppViewProjectionCacheTTL.unreadCountsSeconds)
      if let projectionCache {
        let snapshot = BootstrapSidebarCacheSnapshot(
          priority: priority.response,
          folderPayload: folders
        )
        if let data = try? JSONEncoder().encode(snapshot),
           let json = String(data: data, encoding: .utf8)
        {
          try? await projectionCache.storeSidebarProjectionJSON(
            viewerDid: auth.did,
            jsonBody: json,
            expiresAt: cacheExpires
          )
        }
        try? await projectionCache.storeUnreadCounts(
          viewerDid: auth.did,
          counts: unreadCounts,
          expiresAt: unreadExpires
        )
      }

      scheduleBackgroundWarmers(
        auth: auth,
        priority: priority.response,
        enrollAuthorDids: priority.response.enrollAuthorDids
      )

      BootstrapStreamTimings.logPhase(
        logger,
        phase: "total",
        startedAt: streamStarted,
        viewerDid: auth.did
      )
    } catch {
      logger.error(
        "Bootstrap stream failed",
        metadata: ["error": .string(String(describing: error))]
      )
      try await writeEvent(.error(error.localizedDescription), writer: &writer)
      try await writeEvent(.done(refreshedAt: refreshedAt), writer: &writer)
    }
    try await writer.finish(nil)
  }

  private func loadFreshCachedSnapshot(viewerDid: String) async throws -> BootstrapSidebarCacheSnapshot? {
    guard let projectionCache else { return nil }
    guard let json = try await projectionCache.cachedSidebarProjectionJSON(viewerDid: viewerDid) else {
      return nil
    }
    return try? JSONDecoder().decode(BootstrapSidebarCacheSnapshot.self, from: Data(json.utf8))
  }

  private func emitCachedBootstrap(
    auth: AuthContext,
    snapshot: BootstrapSidebarCacheSnapshot,
    refreshedAt: Date,
    writer: inout any ResponseBodyWriter
  ) async throws {
    try await writeEvent(.sidebarPriority(snapshot.priority), writer: &writer)

    var unreadCounts = await projectionService.unreadCountsMap(
      for: snapshot.priority.allPublicationRows
        + snapshot.priority.myPublications
        + snapshot.priority.subscribedUnfoldered
        + snapshot.priority.followingTabPublications
    )
    if unreadCounts.isEmpty,
       let cachedCounts = try await projectionCache?.cachedUnreadCounts(viewerDid: auth.did)
    {
      unreadCounts = cachedCounts
    }
    try await writeEvent(.unreadCounts(unreadCounts), writer: &writer)

    if let folders = snapshot.folderPayload {
      try await writeEvent(.sidebarFolders(folders), writer: &writer)
    }

    if let selectedId = BootstrapStreamSelection.firstUnreadPublicationId(
      myPublications: snapshot.priority.myPublications,
      subscribedUnfoldered: snapshot.priority.subscribedUnfoldered,
      following: snapshot.priority.followingTabPublications,
      unreadCounts: unreadCounts
    ) {
      try await writeEvent(.selectedPublication(publicationId: selectedId), writer: &writer)
      if let row = BootstrapStreamSelection.row(publicationId: selectedId, in: snapshot.priority),
         let page = try await readService.cachedOrListedFirstPage(
           auth: auth,
           publicationId: selectedId,
           scope: row.appViewScope,
           limit: 50
         )
      {
        let payload = AppViewBootstrapEntriesPagePayload(
          publicationId: selectedId,
          entries: page.entries.map(Self.bootstrapEntry),
          cursor: page.cursor
        )
        try await writeEvent(.entriesPage(payload), writer: &writer)
      }
    }

    try await writeEvent(.done(refreshedAt: refreshedAt), writer: &writer)
  }

  private func scheduleBackgroundRefresh(auth: AuthContext, priority: PublicationSidebarResponse) {
    Task {
      do {
        _ = try await self.projectionService.bootstrapPrioritySidebar(auth: auth)
        _ = priority
      } catch {
        self.logger.warning(
          "Background sidebar refresh failed",
          metadata: ["error": .string(String(describing: error))]
        )
      }
    }
  }

  private func scheduleBackgroundWarmers(
    auth: AuthContext,
    priority: PublicationSidebarResponse,
    enrollAuthorDids: [String]
  ) {
    let priorityAuthorDids = BootstrapStreamSelection.priorityAuthorDids(from: priority)
    Task {
      if !priorityAuthorDids.isEmpty {
        do {
          _ = try await self.enrollService.enroll(
            auth: auth,
            authorDids: priorityAuthorDids,
            recentOnly: true
          )
        } catch {
          self.logger.warning(
            "Bootstrap stream priority enroll failed",
            metadata: ["error": .string(String(describing: error))]
          )
        }
      }

      do {
        _ = try await self.skyreaderIngestionService.ingestViewerSubscriptions(auth: auth)
      } catch {
        self.logger.warning(
          "Bootstrap stream Skyreader RSS ingest failed",
          metadata: ["error": .string(String(describing: error))]
        )
      }

      let warmedAuthorDids = Set(priorityAuthorDids)
      let remainingAuthorDids = enrollAuthorDids.filter {
        ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid($0) && !warmedAuthorDids.contains($0)
      }
      if !remainingAuthorDids.isEmpty {
        do {
          _ = try await self.enrollService.enroll(
            auth: auth,
            authorDids: remainingAuthorDids,
            recentOnly: false
          )
        } catch {
          self.logger.warning(
            "Bootstrap stream bulk enroll failed",
            metadata: ["error": .string(String(describing: error))]
          )
        }
      }
    }
  }

  private func scheduleSelectedPublicationWarmers(
    auth: AuthContext,
    row: SidebarPublicationRow,
    priorityAuthorDids: [String]
  ) {
    Task {
      await self.warmSelectedPublication(auth: auth, row: row, priorityAuthorDids: priorityAuthorDids)
    }
  }

  private func warmSelectedPublication(
    auth: AuthContext,
    row: SidebarPublicationRow,
    priorityAuthorDids: [String]
  ) async {
    let warmedAuthorDids = Set(priorityAuthorDids)
    if row.publicationId.hasPrefix(PublicationLexicons.rssPublicationPrefix),
       let feedUrl = PublicationProjectionLogic.normalizedFeedUrlFromRssPublicationId(row.publicationId)
    {
      do {
        _ = try await skyreaderIngestionService.ingestViewerSubscriptions(
          auth: auth,
          priorityFeedUrls: [feedUrl]
        )
      } catch {
        logger.warning(
          "Bootstrap stream selected RSS feed ingest failed",
          metadata: ["publicationId": .string(row.publicationId)]
        )
      }
    } else if !warmedAuthorDids.contains(row.appViewScope.authorDid) {
      do {
        _ = try await enrollService.enroll(
          auth: auth,
          authorDids: [row.appViewScope.authorDid],
          recentOnly: true
        )
      } catch {
        logger.warning(
          "Bootstrap stream selected publication enroll failed",
          metadata: ["publicationId": .string(row.publicationId)]
        )
      }
    }
  }

  private static func bootstrapEntry(_ item: AppViewEntryListItem) -> AppViewBootstrapEntryListItem {
    AppViewBootstrapEntryListItem(
      entryId: item.entryId,
      title: item.title,
      summary: item.summary,
      publishedAt: item.publishedAt,
      thumbnailUrl: item.thumbnailUrl,
      thumbnailFallbackUrl: item.thumbnailFallbackUrl
    )
  }

  private func writeEvent(
    _ event: AppViewBootstrapStreamEvent,
    writer: inout any ResponseBodyWriter
  ) async throws {
    let line = try AppViewBootstrapStreamNDJSON.encodeLine(event)
    var buffer = ByteBuffer()
    buffer.writeBytes(line)
    try await writer.write(buffer)
  }
}
