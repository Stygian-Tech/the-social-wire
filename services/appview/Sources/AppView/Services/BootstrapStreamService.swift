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

  private enum SidebarBootstrapChunk: Sendable {
    case unreadCounts(PublicationProjectionService.UnreadCounterSnapshot)
    case folders(AppViewBootstrapSidebarFoldersPayload)
  }

  private struct EntriesPageEvidence: Sendable {
    let source: AppViewBootstrapEvidenceSource
    let cachedAt: Date?
  }

  func writeStream(auth: AuthContext, writer: inout any ResponseBodyWriter) async throws {
    let streamStarted = Date()
    let refreshedAt = Date()
    var cachedEvidenceAt: Date?
    do {
      if let cached = try await loadFreshCachedSnapshot(viewerDid: auth.did) {
        cachedEvidenceAt = cached.cachedAt
        try await emitCachedBootstrap(
          auth: auth,
          snapshot: cached.snapshot,
          refreshedAt: cached.cachedAt,
          writer: &writer
        )
        scheduleBackgroundWarmers(
          auth: auth,
          priority: cached.snapshot.priority,
          enrollAuthorDids: cached.snapshot.priority.enrollAuthorDids
        )
        scheduleBackgroundRefresh(auth: auth, priority: cached.snapshot.priority)
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

      let unreadRows = priority.response.allPublicationRows
        + priority.response.myPublications
        + priority.response.subscribedUnfoldered
        + priority.response.followingTabPublications

      let unreadStarted = Date()
      let foldersStarted = Date()
      var unreadCounts: [String: Int] = [:]
      var folders: AppViewBootstrapSidebarFoldersPayload?
      var selectedId: String?
      var selectedRow: SidebarPublicationRow?
      var selectedEnrollTask: Task<Void, Never>?
      var emittedSelectedEntries = false
      var completionSource = AppViewBootstrapEvidenceSource.liveProjection
      var cachedEntriesEvidenceAt: Date?
      var priorityExactCountsTask: Task<PublicationProjectionService.UnreadCounterSnapshot, Never>?
      var folderExactCountsTask: Task<PublicationProjectionService.UnreadCounterSnapshot, Never>?

      try await withThrowingTaskGroup(of: SidebarBootstrapChunk.self) { group in
        group.addTask {
          .unreadCounts(
            await projectionService.unreadCounterSnapshot(
              for: unreadRows,
              viewerDid: auth.did
            )
          )
        }
        group.addTask {
          .folders(
            try await projectionService.bootstrapFolderSidebar(
              auth: auth,
              context: priority.context
            )
          )
        }

        for try await chunk in group {
          switch chunk {
          case .unreadCounts(let snapshot):
            let counts = snapshot.counts
            unreadCounts = counts
            let unreadPublicationIds = unreadRows.map(\.publicationId)
            try await writeEvent(
              .unreadCounts(
                counts,
                replacePublicationIds: unreadPublicationIds,
                generation: snapshot.generation,
                accuracy: snapshot.accuracy.rawValue,
                countedAt: snapshot.countedAt
              ),
              writer: &writer
            )
            if snapshot.dirty || !snapshot.missingPublicationIds.isEmpty {
              priorityExactCountsTask = Task {
                await self.projectionService.refreshUnreadCounterSnapshot(
                  for: unreadRows,
                  viewerDid: auth.did
                )
              }
            }
            BootstrapStreamTimings.logPhase(
              logger,
              phase: "unreadCounts",
              startedAt: unreadStarted,
              viewerDid: auth.did,
              extra: [
                "publicationCount": "\(counts.count)",
                "accuracy": snapshot.accuracy.rawValue,
              ]
            )

            selectedId = BootstrapStreamSelection.firstUnreadPublicationId(
              myPublications: priority.response.myPublications,
              subscribedUnfoldered: priority.response.subscribedUnfoldered,
              following: priority.response.followingTabPublications,
              unreadCounts: counts
            )
            selectedRow = selectedId.flatMap {
              BootstrapStreamSelection.row(publicationId: $0, in: priority.response)
            }
            selectedEnrollTask = selectedRow.map { row in
              Task { await self.enrollAuthorForBootstrap(auth: auth, row: row) }
            }
            if let selectedId, let selectedRow {
              emittedSelectedEntries = true
              try await writeEvent(.selectedPublication(publicationId: selectedId), writer: &writer)
              let entriesStarted = Date()
              let entriesEvidence = try await writeBootstrapEntriesPage(
                auth: auth,
                publicationId: selectedId,
                row: selectedRow,
                enrollTask: selectedEnrollTask,
                writer: &writer
              )
              completionSource = BootstrapStreamCompletionEvidence.combined(
                completionSource,
                entriesEvidence.source
              )
              cachedEntriesEvidenceAt = BootstrapStreamCompletionEvidence.oldest(
                cachedEntriesEvidenceAt,
                entriesEvidence.cachedAt
              )
              BootstrapStreamTimings.logPhase(
                logger,
                phase: "entriesPage",
                startedAt: entriesStarted,
                viewerDid: auth.did
              )
            }

          case .folders(let payload):
            folders = payload
            try await writeSidebarSections(
              payload,
              unreadCounts: nil,
              refreshedAt: refreshedAt,
              writer: &writer
            )
            try await writeEvent(.sidebarFolders(payload), writer: &writer)
            BootstrapStreamTimings.logPhase(
              logger,
              phase: "folderSidebar",
              startedAt: foldersStarted,
              viewerDid: auth.did
            )
          }
        }
      }

      guard let folders else {
        throw HTTPError(.internalServerError, message: "Bootstrap folder sidebar did not complete.")
      }

      let priorityPublicationIds = Set(unreadRows.map(\.publicationId))
      let folderUnreadRows = folders.allPublicationRows.filter {
        !priorityPublicationIds.contains($0.publicationId)
      }
      var folderUnreadCounts: [String: Int] = [:]
      if !folderUnreadRows.isEmpty {
        let folderUnreadStarted = Date()
        let folderSnapshot = await projectionService.unreadCounterSnapshot(
          for: folderUnreadRows,
          viewerDid: auth.did
        )
        folderUnreadCounts = folderSnapshot.counts
        let folderPublicationIds = folderUnreadRows.map(\.publicationId)
        try await writeEvent(
          .unreadCounts(
            folderUnreadCounts,
            replacePublicationIds: folderPublicationIds,
            generation: folderSnapshot.generation,
            accuracy: folderSnapshot.accuracy.rawValue,
            countedAt: folderSnapshot.countedAt
          ),
          writer: &writer
        )
        if folderSnapshot.dirty || !folderSnapshot.missingPublicationIds.isEmpty {
          folderExactCountsTask = Task {
            await self.projectionService.refreshUnreadCounterSnapshot(
              for: folderUnreadRows,
              viewerDid: auth.did
            )
          }
        }
        BootstrapStreamTimings.logPhase(
          logger,
          phase: "folderUnreadCounts",
          startedAt: folderUnreadStarted,
          viewerDid: auth.did,
          extra: [
            "publicationCount": "\(folderUnreadCounts.count)",
            "accuracy": folderSnapshot.accuracy.rawValue,
          ]
        )
      }

      if !emittedSelectedEntries, let selectedId, let selectedRow {
        try await writeEvent(.selectedPublication(publicationId: selectedId), writer: &writer)
        let entriesStarted = Date()
        let entriesEvidence = try await writeBootstrapEntriesPage(
          auth: auth,
          publicationId: selectedId,
          row: selectedRow,
          enrollTask: selectedEnrollTask,
          writer: &writer
        )
        completionSource = BootstrapStreamCompletionEvidence.combined(
          completionSource,
          entriesEvidence.source
        )
        cachedEntriesEvidenceAt = BootstrapStreamCompletionEvidence.oldest(
          cachedEntriesEvidenceAt,
          entriesEvidence.cachedAt
        )
        BootstrapStreamTimings.logPhase(
          logger,
          phase: "selectedEntryPage",
          startedAt: entriesStarted,
          viewerDid: auth.did,
          extra: ["publicationId": selectedId]
        )

        scheduleSelectedPublicationWarmers(
          auth: auth,
          row: selectedRow,
          priorityAuthorDids: BootstrapStreamSelection.priorityAuthorDids(from: priority.response),
          skipAuthorEnroll: selectedEnrollTask != nil
        )
      }

      if let priorityExactCountsTask {
        let exact = await priorityExactCountsTask.value
        try await writeEvent(
          .unreadCounts(
            exact.counts,
            replacePublicationIds: unreadRows.map(\.publicationId),
            generation: exact.generation,
            accuracy: exact.accuracy.rawValue,
            countedAt: exact.countedAt
          ),
          writer: &writer
        )
      }

      if let folderExactCountsTask {
        let exact = await folderExactCountsTask.value
        try await writeEvent(
          .unreadCounts(
            exact.counts,
            replacePublicationIds: folderUnreadRows.map(\.publicationId),
            generation: exact.generation,
            accuracy: exact.accuracy.rawValue,
            countedAt: exact.countedAt
          ),
          writer: &writer
        )
      }

      try await writeEvent(
        .done(
          refreshedAt: completionSource == .projectionCache
            ? cachedEntriesEvidenceAt ?? refreshedAt
            : refreshedAt,
          source: completionSource
        ),
        writer: &writer
      )

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
          counts: unreadCounts.merging(folderUnreadCounts) { current, _ in current },
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
      try await writeEvent(
        BootstrapStreamCompletionEvidence.failed(
          attemptedAt: refreshedAt,
          cachedAt: cachedEvidenceAt
        ),
        writer: &writer
      )
    }
    try await writer.finish(nil)
  }

  private func loadFreshCachedSnapshot(
    viewerDid: String
  ) async throws -> (snapshot: BootstrapSidebarCacheSnapshot, cachedAt: Date)? {
    guard let projectionCache else { return nil }
    guard let entry = try await projectionCache.sidebarProjectionCacheEntry(viewerDid: viewerDid) else {
      return nil
    }
    guard
      let snapshot = try? JSONDecoder().decode(
        BootstrapSidebarCacheSnapshot.self,
        from: Data(entry.value.utf8)
      )
    else { return nil }
    return (snapshot, entry.cachedAt)
  }

  private func emitCachedBootstrap(
    auth: AuthContext,
    snapshot: BootstrapSidebarCacheSnapshot,
    refreshedAt: Date,
    writer: inout any ResponseBodyWriter
  ) async throws {
    try await writeEvent(.sidebarPriority(snapshot.priority), writer: &writer)

    let unreadRows = Self.cachedBootstrapUnreadRows(from: snapshot)
    let unreadPublicationIds = unreadRows.map(\.publicationId)
    let counterSnapshot = await projectionService.unreadCounterSnapshot(
      for: unreadRows,
      viewerDid: auth.did
    )
    let unreadCounts = counterSnapshot.counts
    let exactUnreadCountsTask: Task<PublicationProjectionService.UnreadCounterSnapshot, Never>?
    if counterSnapshot.dirty || !counterSnapshot.missingPublicationIds.isEmpty {
      exactUnreadCountsTask = Task {
        await self.projectionService.refreshUnreadCounterSnapshot(
          for: unreadRows,
          viewerDid: auth.did
        )
      }
    } else {
      exactUnreadCountsTask = nil
    }
    try await writeEvent(
      .unreadCounts(
        unreadCounts,
        replacePublicationIds: unreadPublicationIds,
        generation: counterSnapshot.generation,
        accuracy: counterSnapshot.accuracy.rawValue,
        countedAt: counterSnapshot.countedAt
      ),
      writer: &writer
    )

    if let folders = snapshot.folderPayload {
      try await writeSidebarSections(
        folders,
        unreadCounts: nil,
        refreshedAt: refreshedAt,
        writer: &writer
      )
      try await writeEvent(.sidebarFolders(folders), writer: &writer)
    }

    if let selectedId = BootstrapStreamSelection.firstUnreadPublicationId(
      myPublications: snapshot.priority.myPublications,
      subscribedUnfoldered: snapshot.priority.subscribedUnfoldered,
      following: snapshot.priority.followingTabPublications,
      unreadCounts: unreadCounts
    ),
      let row = BootstrapStreamSelection.row(publicationId: selectedId, in: snapshot.priority)
    {
      let selectedEnrollTask = Task { await self.enrollAuthorForBootstrap(auth: auth, row: row) }
      try await writeEvent(.selectedPublication(publicationId: selectedId), writer: &writer)
      _ = try await writeBootstrapEntriesPage(
        auth: auth,
        publicationId: selectedId,
        row: row,
        enrollTask: selectedEnrollTask,
        writer: &writer
      )
    }

    if let exactUnreadCountsTask {
      let exact = await exactUnreadCountsTask.value
      try await writeEvent(
        .unreadCounts(
          exact.counts,
          replacePublicationIds: unreadPublicationIds,
          generation: exact.generation,
          accuracy: exact.accuracy.rawValue,
          countedAt: exact.countedAt
        ),
        writer: &writer
      )
    }

    try await writeEvent(
      .done(refreshedAt: refreshedAt, source: .projectionCache),
      writer: &writer
    )
  }

  private func scheduleBackgroundRefresh(auth: AuthContext, priority: PublicationSidebarResponse) {
    Task {
      do {
        _ = try await self.projectionService.refreshFullDiscoverySidebar(auth: auth)
        let refreshed = try await self.projectionService.bootstrapPrioritySidebar(auth: auth)
        let folders = try await self.projectionService.bootstrapFolderSidebar(
          auth: auth,
          context: refreshed.context
        )
        guard let projectionCache else { return }
        let cacheExpires = Date().addingTimeInterval(AppViewProjectionCacheTTL.sidebarSeconds)
        let snapshot = BootstrapSidebarCacheSnapshot(
          priority: refreshed.response,
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
    priorityAuthorDids: [String],
    skipAuthorEnroll: Bool = false
  ) {
    Task {
      await self.warmSelectedPublication(
        auth: auth,
        row: row,
        priorityAuthorDids: priorityAuthorDids,
        skipAuthorEnroll: skipAuthorEnroll
      )
    }
  }

  private func warmSelectedPublication(
    auth: AuthContext,
    row: SidebarPublicationRow,
    priorityAuthorDids: [String],
    skipAuthorEnroll: Bool = false
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
    } else if !skipAuthorEnroll, !warmedAuthorDids.contains(row.appViewScope.authorDid) {
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

  private func writeBootstrapEntriesPage(
    auth: AuthContext,
    publicationId: String,
    row: SidebarPublicationRow,
    enrollTask: Task<Void, Never>?,
    writer: inout any ResponseBodyWriter
  ) async throws -> EntriesPageEvidence {
    // If PDS backfill finished while folder sidebar loaded, prefer a fresh index read.
    if await enrollAlreadyFinished(enrollTask),
       let page = try await readService.liveFirstPage(auth: auth, scope: row.appViewScope, limit: 50)
    {
      try await emitBootstrapEntriesPage(
        publicationId: publicationId,
        page: page,
        source: .liveProjection,
        writer: &writer
      )
      return EntriesPageEvidence(source: .liveProjection, cachedAt: nil)
    }

    // Stale-first: paint cached page 1 without blocking on PDS backfill.
    if let cached = try await readService.cachedFirstPageIfAvailable(
      auth: auth,
      publicationId: publicationId,
      scope: row.appViewScope,
      limit: 50
    ) {
      let cachedSource = AppViewBootstrapEvidenceSource(rawValue: cached.source.rawValue)
        ?? .unavailable
      try await emitBootstrapEntriesPage(
        publicationId: publicationId,
        page: cached.value,
        source: cachedSource,
        cachedAt: cached.cachedAt,
        expiresAt: cached.expiresAt,
        writer: &writer
      )
      return EntriesPageEvidence(source: cachedSource, cachedAt: cached.cachedAt)
    }

    // Cold path: do not block the stream on PDS enroll — client refreshes feed after `done`.
    if let enrollTask {
      Task { await enrollTask.value }
    } else {
      Task { await enrollAuthorForBootstrap(auth: auth, row: row) }
    }
    try await emitBootstrapEntriesPage(
      publicationId: publicationId,
      page: AppViewEntryListResponse(entries: [], cursor: nil),
      source: .unavailable,
      writer: &writer
    )
    return EntriesPageEvidence(source: .unavailable, cachedAt: nil)
  }

  /// Stale-first unread map for cached bootstrap; fresh replacement is emitted by `emitCachedBootstrap`.
  private func cachedBootstrapUnreadCounts(viewerDid: String) async -> [String: Int]? {
    if let projectionCache,
       let cached = try? await projectionCache.cachedUnreadCounts(viewerDid: viewerDid),
       !cached.isEmpty
    {
      return cached
    }
    return nil
  }

  private func storeCachedUnreadCounts(_ counts: [String: Int], viewerDid: String) async {
    guard let projectionCache, !counts.isEmpty else { return }
    let expiresAt = Date().addingTimeInterval(AppViewProjectionCacheTTL.unreadCountsSeconds)
    try? await projectionCache.storeUnreadCounts(
      viewerDid: viewerDid,
      counts: counts,
      expiresAt: expiresAt
    )
  }

  private static func cachedBootstrapUnreadRows(
    from snapshot: BootstrapSidebarCacheSnapshot
  ) -> [SidebarPublicationRow] {
    var rows: [SidebarPublicationRow] = []
    var seen = Set<String>()
    let append = { (row: SidebarPublicationRow) in
      guard !seen.contains(row.publicationId) else { return }
      seen.insert(row.publicationId)
      rows.append(row)
    }
    for row in snapshot.priority.allPublicationRows { append(row) }
    for row in snapshot.priority.myPublications { append(row) }
    for row in snapshot.priority.subscribedUnfoldered { append(row) }
    for row in snapshot.priority.followingTabPublications { append(row) }
    for row in snapshot.folderPayload?.allPublicationRows ?? [] { append(row) }
    return rows
  }

  private func emitBootstrapEntriesPage(
    publicationId: String,
    page: AppViewEntryListResponse,
    source: AppViewBootstrapEvidenceSource,
    cachedAt: Date? = nil,
    expiresAt: Date? = nil,
    writer: inout any ResponseBodyWriter
  ) async throws {
    let payload = AppViewBootstrapEntriesPagePayload(
      publicationId: publicationId,
      entries: page.entries.map(Self.bootstrapEntry),
      cursor: page.cursor,
      source: source,
      cachedAt: cachedAt,
      expiresAt: expiresAt
    )
    try await writeEvent(.entriesPage(payload), writer: &writer)
  }

  private func writeSidebarSections(
    _ payload: AppViewBootstrapSidebarFoldersPayload,
    unreadCounts: [String: Int]?,
    refreshedAt: Date,
    writer: inout any ResponseBodyWriter
  ) async throws {
    let sectionGeneration = AppViewUnreadCounterSupport.generation(for: refreshedAt)
    for section in payload.folderSections {
      let publicationIds = section.publications.map(\.publicationId)
      let sectionCounts: [String: Int]?
      if let unreadCounts {
        sectionCounts = Dictionary(
          uniqueKeysWithValues: publicationIds.map { ($0, unreadCounts[$0] ?? 0) }
        )
      } else {
        sectionCounts = nil
      }
      try await writeEvent(
        .sidebarSection(
          AppViewBootstrapSidebarSectionPayload(
            sectionKey: "folder:\(section.folderRkey)",
            folderRkey: section.folderRkey,
            folderUri: section.folderUri,
            publications: section.publications,
            unreadCounts: sectionCounts,
            replacePublicationIds: unreadCounts == nil ? nil : publicationIds,
            sectionGeneration: sectionGeneration,
            refreshedAt: refreshedAt
          )
        ),
        writer: &writer
      )
    }
  }

  /// Returns true when enroll finished without waiting (used to pick live vs cached bootstrap page 1).
  private func enrollAlreadyFinished(_ task: Task<Void, Never>?) async -> Bool {
    guard let task else { return false }
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await task.value
        return true
      }
      group.addTask {
        await Task.yield()
        return false
      }
      let finished = await group.next() ?? false
      group.cancelAll()
      return finished
    }
  }

  /// PDS backfill for bootstrap page 1 — runs in parallel with folder sidebar when possible.
  private func enrollAuthorForBootstrap(auth: AuthContext, row: SidebarPublicationRow) async {
    if row.publicationId.hasPrefix(PublicationLexicons.rssPublicationPrefix),
       let feedUrl = PublicationProjectionLogic.normalizedFeedUrlFromRssPublicationId(row.publicationId)
    {
      _ = try? await skyreaderIngestionService.ingestViewerSubscriptions(
        auth: auth,
        priorityFeedUrls: [feedUrl]
      )
      return
    }

    let authorDid = row.appViewScope.authorDid
    guard ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(authorDid) else { return }
    do {
      _ = try await enrollService.enroll(
        auth: auth,
        authorDids: [authorDid],
        recentOnly: true
      )
    } catch {
      logger.warning(
        "Bootstrap stream pre-page enroll failed",
        metadata: [
          "publicationId": .string(row.publicationId),
          "error": .string(String(describing: error)),
        ]
      )
    }
  }

  private static func bootstrapEntry(_ item: AppViewEntryListItem) -> AppViewBootstrapEntryListItem {
    AppViewBootstrapEntryListItem(
      entryId: item.entryId,
      title: item.title,
      summary: item.summary,
      publishedAt: item.publishedAt,
      thumbnailUrl: item.thumbnailUrl,
      thumbnailFallbackUrl: item.thumbnailFallbackUrl,
      originalUrl: item.originalUrl
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

enum BootstrapStreamCompletionEvidence {
  static func oldest(_ current: Date?, _ next: Date?) -> Date? {
    switch (current, next) {
    case (.none, .none): nil
    case (.some(let current), .none): current
    case (.none, .some(let next)): next
    case (.some(let current), .some(let next)): min(current, next)
    }
  }

  static func combined(
    _ current: AppViewBootstrapEvidenceSource,
    _ next: AppViewBootstrapEvidenceSource
  ) -> AppViewBootstrapEvidenceSource {
    if current == .unavailable || next == .unavailable { return .unavailable }
    if current == .projectionCache || next == .projectionCache { return .projectionCache }
    return .liveProjection
  }

  static func failed(
    attemptedAt: Date,
    cachedAt: Date?
  ) -> AppViewBootstrapStreamEvent {
    .done(
      refreshedAt: cachedAt ?? attemptedAt,
      source: cachedAt == nil ? .unavailable : .projectionCache
    )
  }
}
