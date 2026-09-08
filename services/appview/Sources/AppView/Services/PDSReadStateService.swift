import Foundation
import GatewayCore
import Hummingbird
import ReadStateCore
import ThinAppViewCore

struct PDSReadStateService: Sendable {
  let store: any PDSReadStateStoring
  let thinStore: any ThinAppViewStore
  let repo: ATProtoAuthenticatedRepoClient
  let publicationService: PublicationProjectionService
  let projectionCache: (any AppViewProjectionCacheStore)?
  private let verifiedChunks = ReadStateVerifiedChunkCache()

  func confirm(viewerDid: String, request: PDSReadStateConfirmRequest) async throws -> PDSReadStateStatus {
    guard !request.manifestCid.isEmpty, request.manifestCid.utf8.count <= 256 else {
      throw HTTPError(.badRequest, message: "manifestCid is required")
    }
    guard let record = try await repo.getRecordWithMetadata(auth: nil, repo: viewerDid,
      collection: ReadStateManifest.collection, rkey: "self"), record.cid == request.manifestCid else {
      throw HTTPError(.conflict, message: "Read-state manifest changed; refresh and retry")
    }
    let manifest: ReadStateManifest = try Self.decode(record.value, cid: request.manifestCid)
    let projection = try await ReadStateGenerationLoader.load(manifest: manifest, viewerDid: viewerDid) { reference in
      try ReadStateValidation.validate(reference, viewerDid: viewerDid)
      if let cached = await verifiedChunks.value(for: reference) { return cached }
      let key = String(reference.uri.split(separator: "/").last ?? "")
      guard let chunkRecord = try await repo.getRecordWithMetadata(auth: nil, repo: viewerDid,
        collection: ReadStateChunk.collection, rkey: key, cid: reference.cid),
        chunkRecord.cid == reference.cid, chunkRecord.uri == reference.uri else {
        throw ReadStateError.incompleteGeneration
      }
      let chunk: ReadStateChunk = try Self.decode(chunkRecord.value, cid: reference.cid)
      try await verifiedChunks.insertVerified(chunk, for: reference)
      return chunk
    }
    // A newer manifest may have committed while the chain was being loaded.
    guard let current = try await repo.getRecordWithMetadata(auth: nil, repo: viewerDid,
      collection: ReadStateManifest.collection, rkey: "self"), current.cid == request.manifestCid else {
      throw HTTPError(.conflict, message: "Read-state manifest changed during verification")
    }
    let status = try await store.activatePDSReadState(viewerDid: viewerDid, manifest: manifest,
      manifestCid: request.manifestCid, projection: projection,
      expectedLegacyRevision: request.expectedLegacyRevision)
    try await projectionCache?.invalidateUnreadCounts(viewerDid: viewerDid, publicationId: nil)
    return status
  }

  func prepare(auth: AuthContext, request: PDSReadStatePrepareRequest) async throws -> PDSReadStatePreparedSelection {
    let now = Date()
    let previewIds = request.previewSubjectUris ?? []
    guard previewIds.count <= 1000, previewIds.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else {
      throw HTTPError(.badRequest, message: "Preview supports at most 1000 cached subject IDs")
    }
    let prior = try await store.pdsReadStateStatus(viewerDid: auth.did)
    let sidebar: PublicationSidebarResponse
    if let cached = await publicationService.cachedSidebarResponse(viewerDid: auth.did) { sidebar = cached }
    else { sidebar = try await publicationService.sidebar(auth: auth) }
    guard ["publication", "folder", "subscribed", "following"].contains(request.scope.kind) else {
      throw HTTPError(.badRequest, message: "Unknown read-state scope")
    }
    let rows = AppViewExtendedRoutes.rows(for: request.scope, sidebar: sidebar)
    let scopes = rows.map { row in PublicationUnreadScope(
      publicationId: row.publicationId, authorDid: row.appViewScope.authorDid,
      publicationAtUri: row.appViewScope.publicationAtUri,
      publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
      publicationSiteUrls: row.appViewScope.publicationSiteUrls) }
    var selection: PDSReadStatePreparedSelection
    if let before = request.before {
      let cutoff = try ReadAgeCalendar.cutoff(before, now: now)
      guard let timeZone = request.timeZone, let referenceDate = request.referenceDate else {
        throw HTTPError(.badRequest, message: "Age selection requires timeZone and referenceDate")
      }
      _ = try ReadAgeCalendar.calendar(timeZone: timeZone)
      let calendar = ReadStateCalendarSelection(cutoff: ReadAgeCalendar.timestamp(cutoff),
        timeZone: timeZone, referenceDate: referenceDate)
      let validation = ReadStateOperation(actionId: "calendar-validation", sequence: 1, state: .read,
        actedAt: ReadAgeCalendar.timestamp(now), subjectUris: ["validation"], calendar: calendar)
      try ReadStateValidation.validate(validation)
      let queryScopes = rows.map { row in AppViewUnreadCounterSupport.publicationScope(
        viewerDid: auth.did, publicationId: row.publicationId, authorDid: row.appViewScope.authorDid,
        publicationAtUri: row.appViewScope.publicationAtUri,
        publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: row.appViewScope.publicationSiteUrls, sectionKeys: []) }
      var ids: [String] = []
      var scannedCount = 0
      var selectionBytes = 0
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      if !queryScopes.isEmpty {
        try await ReadAgeSnapshot.forEachPage { cursor in
          try await thinStore.listUnreadEntriesForReadMutation(viewerDid: auth.did,
            scopes: queryScopes, cursor: cursor, limit: 100)
        } onPage: { entries in
          scannedCount += entries.count
          let selected = entries.filter { $0.publishedAt < cutoff }.map(\.entryId)
          selectionBytes += selected.reduce(0) { $0 + $1.utf8.count + 4 }
          ids.append(contentsOf: selected)
          // Fail the action rather than truncate an exact selection or exhaust the service.
          guard ids.count <= 100_000, scannedCount <= 250_000,
                selectionBytes <= 8 * 1024 * 1024, ContinuousClock.now < deadline else {
            throw HTTPError(.contentTooLarge, message: "Select a smaller read scope")
          }
        }
      }
      selection = PDSReadStatePreparedSelection(actedAt: ReadAgeCalendar.timestamp(now), selection: .exact,
        boundaries: nil, subjectUris: ids, calendar: calendar, legacyRevision: prior.legacyRevision,
        manifestCid: prior.manifestCid)
    } else {
      let boundaries = try await store.preparePDSReadStateBoundaries(viewerDid: auth.did, scopes: scopes, at: now)
      selection = PDSReadStatePreparedSelection(actedAt: ReadAgeCalendar.timestamp(now), selection: .boundaries,
        boundaries: boundaries, subjectUris: nil, calendar: nil, legacyRevision: prior.legacyRevision,
        manifestCid: prior.manifestCid)
    }
    if let boundaries = selection.boundaries, request.previewSubjectUris != nil {
      selection.previewSubjectUris = try await store.previewPDSReadStateBoundaries(viewerDid: auth.did,
        boundaries: boundaries, subjectUris: previewIds)
    }
    let current = try await store.pdsReadStateStatus(viewerDid: auth.did)
    guard current.legacyRevision == prior.legacyRevision, current.manifestCid == prior.manifestCid else {
      throw HTTPError(.conflict, message: "Read state changed during selection; refresh and retry")
    }
    return selection
  }

  private static func decode<T: Decodable>(_ record: PdsRecordJSON, cid: String) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: record.values, options: [.withoutEscapingSlashes])
    guard data.count <= ReadStateValidation.maximumRecordBytes else { throw ReadStateError.sizeLimit }
    try ReadStateRecordCID.verify(json: data, cid: cid)
    return try JSONDecoder().decode(T.self, from: data)
  }
}
