import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import NIOCore
import OperationsCore

struct OperationsRoutes {
  static let eventStreamPollIntervalSeconds: TimeInterval = 1
  static let liveRefetchAllowanceSeconds: TimeInterval = 2
  static let liveVisibilityBudgetSeconds: TimeInterval = 5

  let store: any OperationsStore
  let config: OperationsConfiguration
  private let auditRecorder: @Sendable (OperationsMutationAudit) async throws -> Void

  init(
    store: any OperationsStore,
    config: OperationsConfiguration,
    auditRecorder: (@Sendable (OperationsMutationAudit) async throws -> Void)? = nil
  ) {
    self.store = store
    self.config = config
    self.auditRecorder = auditRecorder ?? { audit in
      try await store.recordAudit(audit)
    }
  }

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/operations/capabilities") { _, _ async -> OperationsCapabilities in
      await capabilityResolver.resolve()
    }
    group.get("/v1/operations/overview") { _, _ async throws -> OperationsOverview in
      try await store.overview(capabilities: await capabilityResolver.resolve())
    }
    group.get("/v1/operations/services") { _, _ async throws -> OperationsServiceListResponse in
      let services = try await store.listServiceStates()
      return OperationsServiceListResponse(
        services: services,
        evidence: OperationsEvidenceResolver.services(services))
    }
    group.get("/v1/operations/ingestion") { _, _ async throws -> IngestionResponse in
      async let serviceStates = store.listServiceStates()
      async let streamStates = store.listStreamStates()
      let services = try await serviceStates
      let sources = try await streamStates
      let authority = OperationsEvidenceResolver.ingestionAuthority(
        services: services, streams: sources)
      return IngestionResponse(
        state: authority.state, sources: sources, evidence: authority.evidence)
    }
    group.get("/v1/operations/ingestion/endpoints") {
      request, _ async throws -> EndpointListResponse in
      let page = try await store.listJetstreamEndpoints(
        limit: try Self.limit(request),
        before: try Self.paginationCursor(request.uri.queryParameters.get("before")))
      return EndpointListResponse(
        endpoints: page.items, nextCursor: page.nextCursor, totalCount: page.totalCount,
        evidence: Self.evidence(
          source: "appview_jetstream_endpoints", itemCount: page.items.count,
          totalCount: page.totalCount, indexedThrough: page.items.map(\.updatedAt).min(),
          validitySeconds: 45, emptyReason: "No Jetstream endpoint observations are available."))
    }
    group.get("/v1/operations/commands") {
      request, _ async throws -> CommandListResponse in
      let page = try await store.listCommands(
        limit: try Self.limit(request),
        before: try Self.paginationCursor(request.uri.queryParameters.get("before")))
      let observedAt = Date()
      return CommandListResponse(
        commands: page.items, nextCursor: page.nextCursor, totalCount: page.totalCount,
        evidence: Self.evidence(
          source: "operations_commands", itemCount: page.items.count,
          totalCount: page.totalCount, indexedThrough: observedAt, validitySeconds: 5,
          emptyReason: "No command records are available.", generatedAt: observedAt))
    }
    group.post("/v1/operations/ingestion/reconnect") {
      request, context async throws -> EditedResponse<OperationsWorkerCommand> in
      guard let operatorDid = context.authContext?.did else { throw HTTPError(.unauthorized) }
      let audit = mutationAuditScope(
        request: request, operatorDid: operatorDid, requestId: context.requestId,
        action: "jetstream.reconnect_requested", targetType: "command", targetId: nil)
      let command = try await auditedMutation(audit) {
        let mutation = try await request.decode(
          as: ReconnectJetstreamRequest.self, context: context)
        audit.update(
          idempotencyKey: mutation.idempotencyKey,
          expectedVersion: mutation.expectedVersion,
          note: mutation.auditNote)
        try validate(mutation)
        try validateIdempotencyHeader(request, bodyKey: mutation.idempotencyKey)
        let capabilities = await capabilityResolver.resolve()
        try Self.require(capabilities.recovery)
        let state = try await store.fetchStreamState(source: "jetstream")
        audit.setBefore([
          "connectionState": state?.connectionState.rawValue ?? "unknown",
          "version": String(state?.version ?? 0),
        ])
        return try await store.createCommand(
          action: .reconnectJetstream, operatorDid: operatorDid, auditNote: mutation.auditNote,
          expectedStreamVersion: mutation.expectedVersion,
          idempotencyKey: mutation.idempotencyKey, requestId: context.requestId, at: Date())
      }
      return EditedResponse(status: .accepted, response: command)
    }

    group.get("/v1/operations/appview") { _, _ async throws -> AppViewOperationsResponse in
      let services = try await store.listServiceStates().filter {
          $0.service == "appview" || $0.service == "gateway"
        }
      return AppViewOperationsResponse(
        services: services,
        evidence: OperationsEvidenceResolver.services(
          services, requiredServices: ["gateway", "appview"],
          source: "operations_service_state.appview"))
    }

    group.get("/v1/operations/gaps") { request, _ async throws -> GapListResponse in
      let view: GapListView
      switch request.uri.queryParameters.get("view") ?? "active" {
      case "active": view = .active
      case "history": view = .history
      case "all": view = .all
      default: throw HTTPError(.badRequest, message: "Unknown gap lifecycle view")
      }
      let page = try await store.listGaps(
        view: view, limit: try Self.limit(request),
        before: try Self.paginationCursor(request.uri.queryParameters.get("before")))
      let observedAt = Date()
      return GapListResponse(
        gaps: page.items, nextCursor: page.nextCursor, totalCount: page.totalCount,
        evidence: Self.evidence(
          source: "appview_ingestion_gaps.\(view.rawValue)", itemCount: page.items.count,
          totalCount: page.totalCount, indexedThrough: observedAt, validitySeconds: 5,
          emptyReason: "No gap records exist in this lifecycle view.", generatedAt: observedAt))
    }
    group.get("/v1/operations/gaps/:id/investigation") {
      _, context async throws -> GapInvestigation in
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      guard let investigation = try await store.investigateGap(id: id) else {
        throw HTTPError(.notFound)
      }
      return investigation
    }
    group.patch("/v1/operations/gaps/:id") { request, context async throws -> IngestionGap in
      guard let operatorDid = context.authContext?.did else { throw HTTPError(.unauthorized) }
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      let audit = mutationAuditScope(
        request: request, operatorDid: operatorDid, requestId: context.requestId,
        action: "gap.mutation_attempt", targetType: "gap", targetId: id)
      return try await auditedMutation(audit) {
        let body = try await request.decode(as: GapUpdateRequest.self, context: context)
        audit.update(
          action: "gap.\(body.status.rawValue)", idempotencyKey: body.idempotencyKey,
          expectedVersion: body.expectedVersion, note: body.auditNote)
        try validate(body)
        try validateIdempotencyHeader(request, bodyKey: body.idempotencyKey)
        try Self.require((await capabilityResolver.resolve()).recovery)
        let current = try await store.fetchGap(id: id)
        audit.setBefore(
          Self.versionedState(status: current?.status.rawValue, version: current?.version))
        return try await store.transitionGap(
          id: id, to: body.status, expectedVersion: body.expectedVersion,
          operatorDid: operatorDid, idempotencyKey: body.idempotencyKey,
          requestId: context.requestId, note: body.auditNote, at: Date())
      }
    }

    group.post("/v1/operations/backfills/dry-run") {
      request, context async throws -> BackfillDryRunResponse in
      let body = try await request.decode(as: BackfillDryRunRequest.self, context: context)
      let normalized = try Self.validate(body)
      try Self.requireMode(normalized.sourceMode, capabilities: await capabilityResolver.resolve())
      return try await store.estimateBackfill(normalized)
    }
    group.get("/v1/operations/backfills") { request, _ async throws -> BackfillListResponse in
      let view: BackfillListView
      switch request.uri.queryParameters.get("view") ?? "active" {
      case "active": view = .active
      case "needs_attention", "attention": view = .attention
      case "history": view = .history
      case "all": view = .all
      default: throw HTTPError(.badRequest, message: "Unknown backfill lifecycle view")
      }
      let page = try await store.listBackfills(
        view: view, limit: try Self.limit(request),
        before: try Self.paginationCursor(request.uri.queryParameters.get("before")))
      let observedAt = Date()
      return BackfillListResponse(
        backfills: page.items, nextCursor: page.nextCursor, totalCount: page.totalCount,
        evidence: Self.evidence(
          source: "appview_backfill_jobs.\(view.rawValue)", itemCount: page.items.count,
          totalCount: page.totalCount, indexedThrough: observedAt, validitySeconds: 5,
          emptyReason: "No backfill jobs exist in this lifecycle view.", generatedAt: observedAt))
    }
    group.post("/v1/operations/backfills") {
      request, context async throws -> EditedResponse<BackfillJob> in
      guard let operatorDid = context.authContext?.did else { throw HTTPError(.unauthorized) }
      let audit = mutationAuditScope(
        request: request, operatorDid: operatorDid, requestId: context.requestId,
        action: "backfill.queued", targetType: "backfill", targetId: nil)
      let job = try await auditedMutation(audit) {
        let body = try await request.decode(as: CreateBackfillRequest.self, context: context)
        audit.update(
          idempotencyKey: body.idempotencyKey, expectedVersion: body.expectedGapVersion,
          note: body.auditNote)
        let normalized = try Self.validate(body.dryRun)
        try validateProductionConfirmation(body.environmentConfirmation)
        try Self.validateIdempotency(body.idempotencyKey)
        try validateIdempotencyHeader(request, bodyKey: body.idempotencyKey)
        guard !body.requestFingerprint.isEmpty else {
          throw HTTPError(.badRequest, message: "requestFingerprint is required")
        }
        if normalized.gapId != nil, body.expectedGapVersion == nil {
          throw HTTPError(.badRequest, message: "expectedGapVersion is required for gap recovery")
        }
        try Self.requireMode(normalized.sourceMode, capabilities: await capabilityResolver.resolve())
        let freshEstimate = try await store.estimateBackfill(normalized)
        guard freshEstimate.conflicts.isEmpty else {
          throw HTTPError(.conflict, message: freshEstimate.conflicts.joined(separator: " "))
        }
        guard freshEstimate.estimatedCount == body.expectedEstimate else {
          throw HTTPError(.conflict, message: "Dry-run estimate changed; review it again")
        }
        let currentGap = try await normalized.gapId.asyncFlatMap {
          try await store.fetchGap(id: $0)
        }
        audit.setBefore(
          Self.versionedState(status: currentGap?.status.rawValue, version: currentGap?.version))
        return try await store.createBackfill(
          body, operatorDid: operatorDid, requestId: context.requestId, at: Date())
      }
      return EditedResponse(status: .created, response: job)
    }
    group.get("/v1/operations/backfills/:id") { _, context async throws -> BackfillJob in
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      guard let job = try await store.fetchBackfill(id: id) else { throw HTTPError(.notFound) }
      return job
    }
    registerBackfillAction("pause", status: .paused, on: group)
    registerBackfillAction("resume", status: .queued, on: group)
    registerBackfillAction("cancel", status: .cancelled, on: group)

    group.get("/v1/operations/alerts") { request, _ async throws -> AlertListResponse in
      let view: AlertListView
      switch request.uri.queryParameters.get("view") ?? "active" {
      case "active": view = .active
      case "history": view = .history
      case "all": view = .all
      default: throw HTTPError(.badRequest, message: "Unknown alert lifecycle view")
      }
      let page = try await store.listAlerts(
        view: view, limit: try Self.limit(request),
        before: try Self.paginationCursor(request.uri.queryParameters.get("before")))
      let observedAt = Date()
      return AlertListResponse(
        alerts: page.items, nextCursor: page.nextCursor, totalCount: page.totalCount,
        evidence: Self.evidence(
          source: "operations_alerts.\(view.rawValue)", itemCount: page.items.count,
          totalCount: page.totalCount, indexedThrough: observedAt, validitySeconds: 5,
          emptyReason: "No alerts exist in this lifecycle view.", generatedAt: observedAt))
    }
    registerAlertAction("acknowledge", status: .acknowledged, on: group)
    registerAlertAction("resolve", status: .resolved, on: group)
    group.post("/v1/operations/alerts/:id/retry") {
      request, context async throws -> EditedResponse<OperationsAlert> in
      guard let operatorDid = context.authContext?.did else { throw HTTPError(.unauthorized) }
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      let audit = mutationAuditScope(
        request: request, operatorDid: operatorDid, requestId: context.requestId,
        action: "alert.delivery_retry", targetType: "alert", targetId: id)
      let alert = try await auditedMutation(audit) {
        let mutation = try await request.decode(
          as: OperatorMutationRequest.self, context: context)
        audit.update(
          idempotencyKey: mutation.idempotencyKey,
          expectedVersion: mutation.expectedVersion,
          note: mutation.auditNote)
        try validate(mutation)
        try validateIdempotencyHeader(request, bodyKey: mutation.idempotencyKey)
        let current = try await store.fetchAlert(id: id)
        audit.setBefore(
          Self.versionedState(status: current?.status.rawValue, version: current?.version))
        return try await store.retryAlertDelivery(
          id: id, expectedVersion: mutation.expectedVersion, operatorDid: operatorDid,
          idempotencyKey: mutation.idempotencyKey, requestId: context.requestId,
          note: mutation.auditNote, at: Date())
      }
      return EditedResponse(status: .accepted, response: alert)
    }

    group.get("/v1/operations/metrics") { request, _ async throws -> MetricListResponse in
      let query = try Self.metricQuery(request)
      let rollups = try await store.listMetricRollups(
        startAt: query.from, endAt: query.to, metricName: query.metric,
        collection: query.collection, limit: 10_000)
      let latestBucketEnd = rollups.map(\.bucketStart).max()?.addingTimeInterval(60)
      let expectedBuckets = max(1, Int(ceil(query.to.timeIntervalSince(query.from) / 60)))
      let observedBuckets = Set(rollups.map { Int($0.bucketStart.timeIntervalSince1970 / 60) }).count
      let generatedAt = Date()
      let truncated = rollups.count == 10_000
      let unavailable = rollups.isEmpty
      let evidence = OperationsEvidenceMetadata(
        source: "operations_metric_rollups",
        accuracy: unavailable ? .unavailable : (truncated ? .sampled : .exact),
        generatedAt: generatedAt, indexedThrough: latestBucketEnd,
        ageSeconds: latestBucketEnd.map { max(0, generatedAt.timeIntervalSince($0)) } ?? 0,
        validUntil: unavailable ? generatedAt : latestBucketEnd!.addingTimeInterval(75),
        coverage: unavailable ? 0 : min(1, Double(observedBuckets) / Double(expectedBuckets)),
        lastSuccessfulAt: latestBucketEnd,
        degradedReason: unavailable
          ? "No closed one-minute metric buckets exist for the requested range."
          : (truncated ? "Metric response reached the 10,000-row safety limit." : nil))
      return MetricListResponse(rollups: rollups, evidence: evidence)
    }

    group.get("/v1/operations/traces") { request, _ async throws -> TraceListResponse in
      let now = Date()
      let from = try Self.optionalDate(request.uri.queryParameters.get("from"))
        ?? now.addingTimeInterval(-15 * 60)
      let to = try Self.optionalDate(request.uri.queryParameters.get("to")) ?? now
      guard from < to, to.timeIntervalSince(from) <= 24 * 60 * 60 else {
        throw HTTPError(.badRequest, message: "Trace range must be positive and no more than 24 hours")
      }
      let page = try await store.listTraceSpans(
        startAt: from, endAt: to, limit: try Self.limit(request, maximum: 500),
        before: try Self.paginationCursor(request.uri.queryParameters.get("before")))
      let generatedAt = Date()
      return TraceListResponse(
        traces: page.items, nextCursor: page.nextCursor, totalCount: page.totalCount,
        truncated: page.nextCursor != nil,
        evidence: Self.traceEvidence(
          page.items, totalCount: page.totalCount, truncated: page.nextCursor != nil,
          generatedAt: generatedAt,
          emptyReason: "No traces exist in the requested range."))
    }
    group.get("/v1/operations/traces/:traceId") { _, context async throws -> TraceListResponse in
      let items = try await store.listTraceSpans(
        limit: 500, traceId: context.parameters.get("traceId"))
      guard !items.isEmpty else { throw HTTPError(.notFound, message: "Trace not found") }
      let generatedAt = Date()
      let truncated = items.count == 500
      return TraceListResponse(
        traces: items, nextCursor: nil, totalCount: items.count, truncated: truncated,
        evidence: Self.traceEvidence(
          items, totalCount: truncated ? nil : items.count, truncated: truncated,
          generatedAt: generatedAt,
          emptyReason: "Trace not found.",
          truncatedReason: "Trace detail reached the 500-span safety limit."))
    }

    group.get("/v1/operations/events/stream") { request, _ async throws -> Response in
      let capabilities = await capabilityResolver.resolve()
      try Self.require(capabilities.eventStream)
      let requestedAfter = try Self.eventCursor(request)
      let bounds = try await store.changeEventCursorBounds()
      let after = try Self.eventStreamCursor(requested: requestedAfter, bounds: bounds)
      var headers = HTTPFields()
      headers[.contentType] = "text/event-stream"
      headers[.cacheControl] = "no-cache, no-store"
      if let name = HTTPField.Name("X-Accel-Buffering") { headers[name] = "no" }
      return Response(
        status: .ok, headers: headers,
        body: ResponseBody { writer in
          var cursor = after
          var lastHeartbeat = Date.distantPast
          try await writer.write(ByteBuffer(
            string: "retry: \(OperationsCapabilityResolver.eventStreamRetryMilliseconds)\n\n"))
          while !Task.isCancelled {
            let events = try await store.listChangeEvents(after: cursor, limit: 100)
            if events.isEmpty {
              let now = Date()
              if now.timeIntervalSince(lastHeartbeat) >= 15 {
                try await writer.write(ByteBuffer(string: Self.sseHeartbeat(at: now)))
                lastHeartbeat = now
              }
            } else {
              for event in events {
                try await writer.write(ByteBuffer(string: try Self.sseFrame(event)))
                cursor = event.cursor
              }
            }
            try await Task.sleep(for: .seconds(Self.eventStreamPollIntervalSeconds))
          }
          try await writer.finish(nil)
        })
    }
  }

  private var capabilityResolver: OperationsCapabilityResolver {
    OperationsCapabilityResolver(store: store, config: config)
  }

  private func registerBackfillAction(
    _ action: String,
    status: BackfillJobStatus,
    on group: RouterGroup<GatewayRequestContext>
  ) {
    group.post("/v1/operations/backfills/:id/\(action)") {
      request, context async throws -> BackfillJob in
      guard let operatorDid = context.authContext?.did else { throw HTTPError(.unauthorized) }
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      let audit = mutationAuditScope(
        request: request, operatorDid: operatorDid, requestId: context.requestId,
        action: "backfill.\(action)", targetType: "backfill", targetId: id)
      return try await auditedMutation(audit) {
        let mutation = try await request.decode(
          as: OperatorMutationRequest.self, context: context)
        audit.update(
          idempotencyKey: mutation.idempotencyKey,
          expectedVersion: mutation.expectedVersion,
          note: mutation.auditNote)
        try validate(mutation)
        try validateIdempotencyHeader(request, bodyKey: mutation.idempotencyKey)
        try Self.require((await capabilityResolver.resolve()).recovery)
        let current = try await store.fetchBackfill(id: id)
        audit.setBefore(
          Self.versionedState(status: current?.status.rawValue, version: current?.version))
        return try await store.transitionBackfill(
          id: id, to: status, expectedVersion: mutation.expectedVersion,
          operatorDid: operatorDid, idempotencyKey: mutation.idempotencyKey,
          requestId: context.requestId, note: mutation.auditNote, failureReason: nil, at: Date())
      }
    }
  }

  private func registerAlertAction(
    _ action: String,
    status: OperationsAlertStatus,
    on group: RouterGroup<GatewayRequestContext>
  ) {
    group.post("/v1/operations/alerts/:id/\(action)") {
      request, context async throws -> OperationsAlert in
      guard let operatorDid = context.authContext?.did else { throw HTTPError(.unauthorized) }
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      let audit = mutationAuditScope(
        request: request, operatorDid: operatorDid, requestId: context.requestId,
        action: "alert.\(action)", targetType: "alert", targetId: id)
      return try await auditedMutation(audit) {
        let mutation = try await request.decode(
          as: OperatorMutationRequest.self, context: context)
        audit.update(
          idempotencyKey: mutation.idempotencyKey,
          expectedVersion: mutation.expectedVersion,
          note: mutation.auditNote)
        try validate(mutation)
        try validateIdempotencyHeader(request, bodyKey: mutation.idempotencyKey)
        let current = try await store.fetchAlert(id: id)
        audit.setBefore(
          Self.versionedState(status: current?.status.rawValue, version: current?.version))
        return try await store.transitionAlert(
          id: id, to: status, expectedVersion: mutation.expectedVersion,
          operatorDid: operatorDid, idempotencyKey: mutation.idempotencyKey,
          requestId: context.requestId, note: mutation.auditNote, at: Date())
      }
    }
  }

  /// Successful state changes are committed with their success audit by the store transaction.
  /// This boundary durably records every rejected or failed authenticated attempt, including
  /// decode, validation, capability, optimistic-concurrency, and persistence failures.
  func auditedMutation<Value>(
    _ audit: OperationsMutationAuditScope,
    operation: () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operation()
    } catch {
      let httpError = Self.httpError(error)
      let responseStatus = (error as? any HTTPResponseError)?.status ?? httpError.status
      do {
        try await auditRecorder(
          audit.failureAudit(error: error, responseStatus: responseStatus))
      } catch {
        throw HTTPError(
          .internalServerError,
          message: "The mutation outcome could not be durably audited")
      }
      if error is any HTTPResponseError { throw error }
      throw httpError
    }
  }

  private func mutationAuditScope(
    request: Request,
    operatorDid: String,
    requestId: String,
    action: String,
    targetType: String,
    targetId: String?
  ) -> OperationsMutationAuditScope {
    let header = HTTPField.Name("Idempotency-Key").flatMap { request.headers[$0] }
    return OperationsMutationAuditScope(
      operatorDid: operatorDid, requestId: requestId, action: action,
      targetType: targetType, targetId: targetId, idempotencyKey: header)
  }

  static func validate(_ request: BackfillDryRunRequest) throws -> BackfillDryRunRequest {
    let collections = request.collections.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard (1...10_000).contains(request.batchSize),
      (1...5_000).contains(request.rateLimit),
      (1...16).contains(request.maxConcurrency),
      !collections.isEmpty,
      collections.count <= 16,
      collections.allSatisfy({ !$0.isEmpty }),
      Set(collections).count == collections.count
    else { throw HTTPError(.badRequest, message: "Backfill bounds are invalid") }
    let repositoryCollections = Set(["site.standard.document", "site.standard.entry"])
    let allowedCollections: Set<String>
    switch request.sourceMode {
    case .tapVerifiedResync, .pdsReconciliation:
      allowedCollections = repositoryCollections
    case .jetstreamReplay:
      allowedCollections = repositoryCollections.union(["app.skyreader.feed.subscription"])
    }
    guard collections.allSatisfy(allowedCollections.contains) else {
      throw HTTPError(
        .badRequest,
        message: "Recovery scope contains an unregistered or unsupported collection")
    }
    if request.sourceMode == .jetstreamReplay {
      guard let start = request.startCursor, let end = request.endCursor, start < end else {
        throw HTTPError(.badRequest, message: "Jetstream replay requires an increasing cursor range")
      }
    }
    do {
      return try BackfillScopePolicy.normalized(BackfillDryRunRequest(
        gapId: request.gapId, sourceMode: request.sourceMode,
        startCursor: request.startCursor, endCursor: request.endCursor,
        collections: collections.sorted(), authorDids: request.authorDids,
        batchSize: request.batchSize, rateLimit: request.rateLimit,
        maxConcurrency: request.maxConcurrency))
    } catch {
      throw HTTPError(.badRequest, message: error.localizedDescription)
    }
  }

  private func validate(_ request: OperatorMutationRequest) throws {
    try Self.validateIdempotency(request.idempotencyKey)
    guard request.expectedVersion >= 0 else {
      throw HTTPError(.badRequest, message: "expectedVersion must be non-negative")
    }
    if let note = request.auditNote, note.count > 280 {
      throw HTTPError(.badRequest, message: "Operator audit note is too long")
    }
    try validateProductionConfirmation(request.environmentConfirmation)
  }

  private func validate(_ request: GapUpdateRequest) throws {
    try validate(OperatorMutationRequest(
      auditNote: request.auditNote,
      environmentConfirmation: request.environmentConfirmation,
      idempotencyKey: request.idempotencyKey,
      expectedVersion: request.expectedVersion))
  }

  private func validate(_ request: ReconnectJetstreamRequest) throws {
    try validate(OperatorMutationRequest(
      auditNote: request.auditNote,
      environmentConfirmation: request.environmentConfirmation,
      idempotencyKey: request.idempotencyKey,
      expectedVersion: request.expectedVersion))
  }

  private func validateIdempotencyHeader(_ request: Request, bodyKey: String) throws {
    let header = HTTPField.Name("Idempotency-Key").flatMap { request.headers[$0] }
    try Self.validateIdempotencyHeader(headerValue: header, bodyKey: bodyKey)
  }

  static func validateIdempotencyHeader(headerValue: String?, bodyKey: String) throws {
    guard let headerValue else {
      throw HTTPError(.badRequest, message: "Idempotency-Key header is required")
    }
    guard headerValue == bodyKey else {
      throw HTTPError(.badRequest, message: "Idempotency-Key header does not match the request body")
    }
  }

  private static func validateIdempotency(_ key: String) throws {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.count <= 128,
      key.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace })
    else { throw HTTPError(.badRequest, message: "A valid idempotencyKey is required") }
  }

  private func validateProductionConfirmation(_ confirmation: String?) throws {
    if config.environment.lowercased() == "prod", confirmation != "PRODUCTION" {
      throw HTTPError(.badRequest, message: "Production confirmation is required")
    }
  }

  private static func requireMode(
    _ mode: BackfillSourceMode,
    capabilities: OperationsCapabilities
  ) throws {
    let capability: OperationsCapability
    switch mode {
    case .tapVerifiedResync: capability = capabilities.recoveryModes.tapVerifiedResync
    case .jetstreamReplay: capability = capabilities.recoveryModes.jetstreamReplay
    case .pdsReconciliation: capability = capabilities.recoveryModes.pdsReconciliation
    }
    try require(capability)
  }

  private static func require(_ capability: OperationsCapability) throws {
    guard capability.enabled else {
      throw HTTPError(
        .serviceUnavailable,
        message: capability.disabledReason ?? "The requested capability is unavailable")
    }
  }

  private static func require(_ capability: OperationsEventStreamCapability) throws {
    guard capability.enabled else {
      throw HTTPError(
        .serviceUnavailable,
        message: capability.disabledReason ?? "The requested capability is unavailable")
    }
  }

  private static func limit(_ request: Request, maximum: Int = 250) throws -> Int {
    guard let raw = request.uri.queryParameters.get("limit") else { return min(100, maximum) }
    guard let value = Int(raw), (1...maximum).contains(value) else {
      throw HTTPError(.badRequest, message: "limit is outside the supported range")
    }
    return value
  }

  static func paginationCursor(_ rawValue: String?) throws -> String? {
    guard let rawValue else { return nil }
    guard OperationsPaginationCursor.decode(rawValue) != nil else {
      throw HTTPError(.badRequest, message: "Pagination cursor is malformed")
    }
    return rawValue
  }

  static func traceEvidence(
    _ spans: [TraceSpan],
    totalCount: Int?,
    truncated: Bool,
    generatedAt: Date = Date(),
    emptyReason: String,
    truncatedReason: String = "The response is a paginated subset of matching trace spans."
  ) -> OperationsEvidenceMetadata {
    guard let indexedThrough = spans.map(\.startedAt).max(), !spans.isEmpty else {
      return OperationsEvidenceMetadata(
        source: "operations_trace_spans", accuracy: .unavailable,
        generatedAt: generatedAt, indexedThrough: nil, ageSeconds: 0,
        validUntil: generatedAt, coverage: 0, lastSuccessfulAt: nil,
        degradedReason: emptyReason)
    }
    let knownPartial = totalCount.map { spans.count < $0 } ?? false
    let sampled = truncated || knownPartial
    let coverage = totalCount.map {
      min(1, Double(spans.count) / Double(max(1, $0)))
    }
    return OperationsEvidenceMetadata(
      source: "operations_trace_spans", accuracy: sampled ? .sampled : .exact,
      generatedAt: generatedAt, indexedThrough: indexedThrough,
      ageSeconds: max(0, generatedAt.timeIntervalSince(indexedThrough)),
      validUntil: indexedThrough.addingTimeInterval(75),
      coverage: coverage, lastSuccessfulAt: indexedThrough,
      degradedReason: sampled ? truncatedReason : nil)
  }

  private static func metricQuery(_ request: Request) throws
    -> (from: Date, to: Date, metric: String?, collection: String?)
  {
    guard let from = try optionalDate(request.uri.queryParameters.get("from")),
      let requestedTo = try optionalDate(request.uri.queryParameters.get("to"))
    else { throw HTTPError(.badRequest, message: "Metrics require ISO-8601 from and to values") }
    guard request.uri.queryParameters.get("resolution") == "1m" else {
      throw HTTPError(.badRequest, message: "Only closed one-minute metric buckets are supported")
    }
    let latestClosedBoundary = Date(
      timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    let to = min(requestedTo, latestClosedBoundary).addingTimeInterval(-0.001)
    guard from < to, to.timeIntervalSince(from) <= 24 * 60 * 60 else {
      throw HTTPError(.badRequest, message: "Metric range must be positive and no more than 24 hours")
    }
    let metric = request.uri.queryParameters.get("metric")
    let collection = request.uri.queryParameters.get("collection")
    guard metric?.count ?? 0 <= 160, collection?.count ?? 0 <= 256 else {
      throw HTTPError(.badRequest, message: "Metric filters are too long")
    }
    return (from, to, metric, collection)
  }

  private static func optionalDate(_ value: String?) throws -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let standard = ISO8601DateFormatter()
    guard let date = standard.date(from: value) else {
      throw HTTPError(.badRequest, message: "Timestamp is not valid ISO-8601")
    }
    return date
  }

  private static func eventCursor(_ request: Request) throws -> Int64? {
    let header = HTTPField.Name("Last-Event-ID").flatMap { request.headers[$0] }
    return try eventCursor(
      queryValue: request.uri.queryParameters.get("after"), lastEventID: header)
  }

  static func eventCursor(queryValue: String?, lastEventID: String?) throws -> Int64? {
    guard let raw = queryValue ?? lastEventID else { return nil }
    guard let cursor = Int64(raw), cursor >= 0 else {
      throw HTTPError(.badRequest, message: "Event cursor must be a non-negative integer")
    }
    return cursor
  }

  static func initialEventCursor(
    requested: Int64?,
    bounds: OperationsChangeEventCursorBounds
  ) -> Int64 {
    requested ?? bounds.latest
  }

  static func eventStreamCursor(
    requested: Int64?,
    bounds: OperationsChangeEventCursorBounds
  ) throws -> Int64 {
    if let requested, requested > bounds.latest {
      throw HTTPError(.badRequest, message: "The requested event cursor is ahead of the durable stream")
    }
    if let requested, !bounds.canResume(after: requested) {
      throw HTTPError(.gone, message: "The requested event cursor has expired")
    }
    return initialEventCursor(requested: requested, bounds: bounds)
  }

  static func sseFrame(_ event: OperationsChangeEvent) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let json = String(data: try encoder.encode(event), encoding: .utf8) ?? "{}"
    return "id: \(event.cursor)\nevent: \(event.eventType)\ndata: \(json)\n\n"
  }

  static func sseHeartbeat(at date: Date) -> String {
    ": heartbeat \(date.ISO8601Format())\n\n"
  }

  static func evidence(
    source: String,
    itemCount: Int,
    totalCount: Int,
    indexedThrough: Date?,
    validitySeconds: TimeInterval,
    emptyReason: String,
    generatedAt: Date = Date()
  ) -> OperationsEvidenceMetadata {
    let unavailable = indexedThrough == nil
    let partial = !unavailable && itemCount < totalCount
    return OperationsEvidenceMetadata(
      source: source,
      accuracy: unavailable ? .unavailable : (partial ? .sampled : .exact),
      generatedAt: generatedAt,
      indexedThrough: unavailable ? nil : indexedThrough,
      ageSeconds: unavailable ? 0 : max(0, generatedAt.timeIntervalSince(indexedThrough!)),
      validUntil: unavailable ? generatedAt : indexedThrough!.addingTimeInterval(validitySeconds),
      coverage: unavailable ? 0
        : (totalCount == 0 ? 1 : min(1, Double(itemCount) / Double(totalCount))),
      lastSuccessfulAt: unavailable ? nil : indexedThrough,
      degradedReason: unavailable ? emptyReason
        : (partial ? "The response is a paginated subset of the matching records." : nil))
  }

  private static func versionedState(status: String?, version: Int?) -> [String: String] {
    var state: [String: String] = [:]
    if let status { state["status"] = status }
    if let version { state["version"] = String(version) }
    return state
  }

  private static func httpError(_ error: Error) -> HTTPError {
    if let error = error as? HTTPError { return error }
    guard let error = error as? OperationsStoreError else {
      return HTTPError(.internalServerError, message: "Operations mutation failed")
    }
    switch error {
    case .notFound: return HTTPError(.notFound)
    case .versionConflict, .invalidTransition, .idempotencyConflict, .overlappingBackfill,
      .backfillScopeChanged:
      return HTTPError(.conflict, message: "Operational state changed; refresh and retry")
    case .invalidBackfillFingerprint:
      return HTTPError(.conflict, message: "Backfill dry-run fingerprint is invalid or expired")
    case .leaseConflict:
      return HTTPError(.conflict, message: "Backfill lease ownership changed")
    case .invalidProgress:
      return HTTPError(.badRequest, message: "Backfill progress is invalid")
    case .environmentMismatch:
      return HTTPError(.conflict, message: "Environment scope does not match")
    case .missingCreatedRecord, .jsonEncoding:
      return HTTPError(.internalServerError, message: "Operations persistence failed")
    case .invalidPaginationCursor:
      return HTTPError(.badRequest, message: "Pagination cursor is malformed")
    }
  }
}

struct GapUpdateRequest: Codable, Sendable {
  let status: IngestionGapStatus
  let auditNote: String?
  let environmentConfirmation: String?
  let idempotencyKey: String
  let expectedVersion: Int
}

struct OperatorMutationRequest: Codable, Sendable {
  let auditNote: String?
  let environmentConfirmation: String?
  let idempotencyKey: String
  let expectedVersion: Int
}

struct ReconnectJetstreamRequest: Codable, Sendable {
  let auditNote: String?
  let environmentConfirmation: String?
  let idempotencyKey: String
  let expectedVersion: Int
}

struct OperationsServiceListResponse: Codable, Sendable {
  let services: [OperationsServiceState]
  let evidence: OperationsEvidenceMetadata
}
struct IngestionResponse: Codable, Sendable {
  let state: IngestionStreamState?
  let sources: [IngestionStreamState]
  let evidence: OperationsEvidenceMetadata
}
struct AppViewOperationsResponse: Codable, Sendable {
  let services: [OperationsServiceState]
  let evidence: OperationsEvidenceMetadata
}
struct EndpointListResponse: Codable, Sendable {
  let endpoints: [JetstreamEndpointState]
  let nextCursor: String?
  let totalCount: Int
  let evidence: OperationsEvidenceMetadata
}
struct CommandListResponse: Codable, Sendable {
  let commands: [OperationsWorkerCommand]
  let nextCursor: String?
  let totalCount: Int
  let evidence: OperationsEvidenceMetadata
}
struct GapListResponse: Codable, Sendable {
  let gaps: [IngestionGap]
  let nextCursor: String?
  let totalCount: Int
  let evidence: OperationsEvidenceMetadata
}
struct BackfillListResponse: Codable, Sendable {
  let backfills: [BackfillJob]
  let nextCursor: String?
  let totalCount: Int
  let evidence: OperationsEvidenceMetadata
}
struct AlertListResponse: Codable, Sendable {
  let alerts: [OperationsAlert]
  let nextCursor: String?
  let totalCount: Int
  let evidence: OperationsEvidenceMetadata
}
struct TraceListResponse: Codable, Sendable {
  let traces: [TraceSpan]
  let nextCursor: String?
  let totalCount: Int
  let truncated: Bool
  let evidence: OperationsEvidenceMetadata
}
struct MetricListResponse: Codable, Sendable {
  let rollups: [OperationsMetricRollup]
  let evidence: OperationsEvidenceMetadata
}

extension Optional where Wrapped == String {
  fileprivate func asyncFlatMap<T>(
    _ transform: (String) async throws -> T?
  ) async rethrows -> T? {
    guard let value = self else { return nil }
    return try await transform(value)
  }
}

extension OperationsOverview: @retroactive ResponseEncodable {}
extension OperationsCapabilities: @retroactive ResponseEncodable {}
extension OperationsServiceState: @retroactive ResponseEncodable {}
extension IngestionStreamState: @retroactive ResponseEncodable {}
extension IngestionGap: @retroactive ResponseEncodable {}
extension GapInvestigation: @retroactive ResponseEncodable {}
extension BackfillDryRunResponse: @retroactive ResponseEncodable {}
extension BackfillJob: @retroactive ResponseEncodable {}
extension OperationsAlert: @retroactive ResponseEncodable {}
extension OperationsWorkerCommand: @retroactive ResponseEncodable {}
extension TraceSpan: @retroactive ResponseEncodable {}
extension OperationsServiceListResponse: ResponseEncodable {}
extension IngestionResponse: ResponseEncodable {}
extension AppViewOperationsResponse: ResponseEncodable {}
extension EndpointListResponse: ResponseEncodable {}
extension CommandListResponse: ResponseEncodable {}
extension GapListResponse: ResponseEncodable {}
extension BackfillListResponse: ResponseEncodable {}
extension AlertListResponse: ResponseEncodable {}
extension TraceListResponse: ResponseEncodable {}
extension MetricListResponse: ResponseEncodable {}
