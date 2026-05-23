import Foundation
import GatewayCore
import Hummingbird
import Logging
import NIOCore
import ThinAppViewCore

enum BootstrapStreamSelection {
  static func priorityAuthorDids(
    from response: PublicationSidebarResponse,
    limit: Int = 16
  ) -> [String] {
    var ordered: [String] = []
    var seen = Set<String>()
    for row in response.myPublications
      + response.subscribedUnfoldered
      + response.followingTabPublications
    {
      let authorDid = row.appViewScope.authorDid
      guard ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(authorDid) else { continue }
      guard seen.insert(authorDid).inserted else { continue }
      ordered.append(authorDid)
      if ordered.count >= limit { break }
    }
    return ordered
  }

  static func firstUnreadPublicationId(
    myPublications: [SidebarPublicationRow],
    subscribedUnfoldered: [SidebarPublicationRow],
    following: [SidebarPublicationRow],
    unreadCounts: [String: Int]
  ) -> String? {
    for row in myPublications + subscribedUnfoldered + following {
      let count = unreadCounts[row.publicationId] ?? row.unreadCount ?? 0
      if count > 0 {
        return row.publicationId
      }
    }
    return nil
  }

  static func row(
    publicationId: String,
    in response: PublicationSidebarResponse
  ) -> SidebarPublicationRow? {
    for row in response.allPublicationRows
      + response.myPublications
      + response.subscribedUnfoldered
      + response.followingTabPublications
    where row.publicationId == publicationId {
      return row
    }
    return nil
  }
}

struct BootstrapStreamService {
  let projectionService: PublicationProjectionService
  let readService: ThinAppViewReadService
  let enrollService: ThinAppViewEnrollService
  let skyreaderIngestionService: ThinAppViewSkyreaderIngestionService
  let logger: Logger

  func writeStream(auth: AuthContext, writer: inout any ResponseBodyWriter) async throws {
    let refreshedAt = Date()
    do {
      let priority = try await projectionService.bootstrapPrioritySidebar(auth: auth)
      try await writeEvent(.sidebarPriority(priority.response), writer: &writer)

      let unreadRows = priority.response.allPublicationRows
        + priority.response.myPublications
        + priority.response.subscribedUnfoldered
        + priority.response.followingTabPublications
      let unreadCounts = await projectionService.unreadCountsMap(for: unreadRows)
      try await writeEvent(.unreadCounts(unreadCounts), writer: &writer)

      let priorityAuthorDids = BootstrapStreamSelection.priorityAuthorDids(from: priority.response)
      if !priorityAuthorDids.isEmpty {
        do {
          _ = try await enrollService.enroll(auth: auth, authorDids: priorityAuthorDids)
        } catch {
          logger.warning(
            "Bootstrap stream priority enroll failed",
            metadata: ["error": .string(String(describing: error))]
          )
        }
      }

      do {
        _ = try await skyreaderIngestionService.ingestViewerSubscriptions(auth: auth)
      } catch {
        logger.warning(
          "Bootstrap stream Skyreader RSS ingest failed",
          metadata: ["error": .string(String(describing: error))]
        )
      }

      let warmedAuthorDids = Set(priorityAuthorDids)
      let remainingAuthorDids = priority.response.enrollAuthorDids.filter {
        ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid($0) && !warmedAuthorDids.contains($0)
      }
      if !remainingAuthorDids.isEmpty {
        Task {
          do {
            _ = try await self.enrollService.enroll(
              auth: auth,
              authorDids: remainingAuthorDids
            )
          } catch {
            self.logger.warning(
              "Bootstrap stream bulk enroll failed",
              metadata: ["error": .string(String(describing: error))]
            )
          }
        }
      }

      if let selectedId = BootstrapStreamSelection.firstUnreadPublicationId(
        myPublications: priority.response.myPublications,
        subscribedUnfoldered: priority.response.subscribedUnfoldered,
        following: priority.response.followingTabPublications,
        unreadCounts: unreadCounts
      ) {
        try await writeEvent(.selectedPublication(publicationId: selectedId), writer: &writer)

        if let row = BootstrapStreamSelection.row(publicationId: selectedId, in: priority.response) {
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
                metadata: ["publicationId": .string(selectedId)]
              )
            }
          } else if !warmedAuthorDids.contains(row.appViewScope.authorDid) {
            do {
              _ = try await enrollService.enroll(auth: auth, authorDids: [row.appViewScope.authorDid])
            } catch {
              logger.warning(
                "Bootstrap stream selected publication enroll failed",
                metadata: ["publicationId": .string(selectedId)]
              )
            }
          }

          do {
            let page = try await readService.listEntries(
              auth: auth,
              authorDid: row.appViewScope.authorDid,
              publicationAtUri: row.appViewScope.publicationAtUri,
              publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
              publicationSiteUrls: row.appViewScope.publicationSiteUrls,
              filter: .all,
              cursor: nil,
              limit: 50
            )
            let payload = AppViewBootstrapEntriesPagePayload(
              publicationId: selectedId,
              entries: page.entries.map(Self.bootstrapEntry),
              cursor: page.cursor
            )
            try await writeEvent(.entriesPage(payload), writer: &writer)
          } catch {
            try await writeEvent(
              .warning("Could not load first feed page for \(selectedId)."),
              writer: &writer
            )
          }
        }
      }

      let folders = try await projectionService.bootstrapFolderSidebar(
        auth: auth,
        context: priority.context
      )
      try await writeEvent(.sidebarFolders(folders), writer: &writer)
      try await writeEvent(.done(refreshedAt: refreshedAt), writer: &writer)
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
