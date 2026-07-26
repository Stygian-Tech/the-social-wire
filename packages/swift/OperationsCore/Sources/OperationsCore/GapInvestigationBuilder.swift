import Foundation

public enum GapInvestigationBuilder {
  public static func window(for gap: IngestionGap) -> (start: Date, end: Date) {
    return (
      gap.detectedAt.addingTimeInterval(-10 * 60),
      gap.detectedAt.addingTimeInterval(10 * 60)
    )
  }

  public static func build(
    gap: IngestionGap,
    events: [OperationsEvent],
    spans: [TraceSpan],
    services: [OperationsServiceState],
    alerts: [OperationsAlert]
  ) -> GapInvestigation {
    let investigationWindow = window(for: gap)
    var evidence = [gapEvidence(gap)]

    evidence.append(contentsOf: events.map(eventEvidence))
    evidence.append(contentsOf: spans.filter(isErrorSpan).map(spanEvidence))
    evidence.append(
      contentsOf: services
        .filter { $0.startedAt >= investigationWindow.start && $0.startedAt <= investigationWindow.end }
        .map(serviceEvidence)
    )
    evidence.append(
      contentsOf: alerts
        .filter { $0.openedAt >= investigationWindow.start && $0.openedAt <= investigationWindow.end }
        .map(alertEvidence)
    )
    evidence.sort { $0.occurredAt < $1.occurredAt }

    let assessment = assess(gap: gap, events: events, evidence: evidence)
    var recommendedActions = [
      "Verify the proposed recovery scope against the gap cursor range before running a backfill."
    ]
    if evidence.contains(where: { $0.traceId != nil }) {
      recommendedActions.append("Open the correlated error trace and inspect its recorded attributes.")
    }
    if assessment.confidence != .high {
      recommendedActions.append("Compare the window with Fly deployment and machine restart history; deployment events are not yet ingested here.")
    }

    return GapInvestigation(
      gap: gap,
      windowStart: investigationWindow.start,
      windowEnd: investigationWindow.end,
      assessment: assessment,
      evidence: evidence,
      recommendedActions: recommendedActions
    )
  }

  private static func assess(
    gap: IngestionGap,
    events: [OperationsEvent],
    evidence: [GapInvestigationEvidence]
  ) -> GapCauseAssessment {
    let overflow = gap.reason == "message_pump_overflow"
    let failures = events.filter { $0.name == "commit.failed" }
    let disconnects = events.filter { $0.name == "jetstream.disconnected" }
    let reconnects = events.filter { $0.name == "jetstream.connected" }
    let restarts = evidence.filter { $0.kind == .service && $0.title == "Service instance started" }
    let persistentLimitation = "This assessment correlates recorded signals; it cannot prove an unobserved upstream or infrastructure root cause."

    if overflow {
      return GapCauseAssessment(
        title: "Worker message pump overflow",
        confidence: .high,
        summary: "The gap detector recorded a message-pump overflow, meaning the worker could not drain received Jetstream messages before its bounded queue filled.",
        evidenceIds: ["gap-detected"],
        limitations: [persistentLimitation]
      )
    }

    if let failure = failures.last {
      let errorType = failure.attributes["error_type"] ?? "redacted error"
      let matchingDisconnect = disconnects.first { abs($0.occurredAt.timeIntervalSince(failure.occurredAt)) <= 60 }
      let confidence: GapCauseAssessment.Confidence = matchingDisconnect == nil ? .medium : .high
      let ids = ["event-\(failure.id)"] + (matchingDisconnect.map { ["event-\($0.id)"] } ?? [])
      return GapCauseAssessment(
        title: "Indexing failure interrupted commit advancement",
        confidence: confidence,
        summary: "The worker recorded a commit failure (\(errorType))\(matchingDisconnect == nil ? " during the gap window." : " immediately before the Jetstream connection was restarted.")",
        evidenceIds: ids,
        limitations: [persistentLimitation, "Error details are deliberately redacted to a bounded category in operations telemetry."]
      )
    }

    if let disconnect = disconnects.last {
      let errorType = disconnect.attributes["error_type"] ?? "unknown error"
      let reconnected = reconnects.contains { $0.occurredAt >= disconnect.occurredAt }
      return GapCauseAssessment(
        title: "Jetstream connection interruption",
        confidence: reconnected ? .medium : .low,
        summary: "The worker recorded a Jetstream disconnect (\(errorType)) during the gap window\(reconnected ? " and subsequently reconnected." : ".")",
        evidenceIds: ["event-\(disconnect.id)"],
        limitations: [persistentLimitation, "The disconnect category may describe the symptom rather than the underlying network or dependency failure."]
      )
    }

    if let restart = restarts.first {
      return GapCauseAssessment(
        title: "Worker instance restart",
        confidence: .medium,
        summary: "An AppView worker instance started inside the gap window, making a restart or deployment a plausible contributor.",
        evidenceIds: [restart.id],
        limitations: [persistentLimitation, "The current service-state record does not distinguish a deployment from an infrastructure restart."]
      )
    }

    if gap.reason == "receive_commit_backlog" {
      return GapCauseAssessment(
        title: "Receive-to-commit backlog at disconnect",
        confidence: .low,
        summary: "The worker had received events that were not durably committed when the stream disconnected. The triggering failure was not retained in the available evidence.",
        evidenceIds: ["gap-detected"],
        limitations: [persistentLimitation, "No correlated failure, disconnect event, or restart was retained for this window."]
      )
    }

    return GapCauseAssessment(
      title: "Cause not determined from retained telemetry",
      confidence: .insufficient,
      summary: "The gap is confirmed, but the available lifecycle events, error spans, alerts, and service starts do not identify a supported trigger.",
      evidenceIds: ["gap-detected"],
      limitations: [persistentLimitation, "Deployment history and external provider incidents are not currently ingested into the Operations store."]
    )
  }

  private static func gapEvidence(_ gap: IngestionGap) -> GapInvestigationEvidence {
    GapInvestigationEvidence(
      id: "gap-detected",
      kind: .gap,
      occurredAt: gap.detectedAt,
      service: gap.source,
      title: "Gap detected",
      detail: gap.reason.replacingOccurrences(of: "_", with: " "),
      attributes: [
        "start_cursor": gap.startCursor.map(String.init) ?? "unknown",
        "end_cursor": gap.endCursor.map(String.init) ?? "unknown",
      ]
    )
  }

  private static func eventEvidence(_ event: OperationsEvent) -> GapInvestigationEvidence {
    let title: String
    let detail: String
    let kind: GapInvestigationEvidence.Kind
    switch event.name {
    case "commit.failed":
      title = "Commit indexing failed"
      detail = event.attributes["error_type"] ?? "The worker recorded a redacted indexing error."
      kind = .indexing
    case "jetstream.disconnected":
      title = "Jetstream disconnected"
      detail = event.attributes["error_type"] ?? "The worker lost its Jetstream connection."
      kind = .stream
    case "jetstream.connected":
      title = "Jetstream connected"
      detail = "The worker established a Jetstream connection."
      kind = .stream
    default:
      title = event.name.replacingOccurrences(of: ".", with: " ")
      detail = "Recorded worker lifecycle event."
      kind = .stream
    }
    return GapInvestigationEvidence(
      id: "event-\(event.id)",
      kind: kind,
      occurredAt: event.occurredAt,
      service: event.service,
      title: title,
      detail: detail,
      attributes: event.attributes,
      traceId: event.traceId
    )
  }

  private static func spanEvidence(_ span: TraceSpan) -> GapInvestigationEvidence {
    GapInvestigationEvidence(
      id: "span-\(span.id)",
      kind: .trace,
      occurredAt: span.startedAt,
      service: span.service,
      title: "Error trace: \(span.name)",
      detail: "The operation failed after \(Int(span.durationMs)) ms.",
      attributes: span.attributes,
      traceId: span.traceId
    )
  }

  private static func serviceEvidence(_ service: OperationsServiceState) -> GapInvestigationEvidence {
    GapInvestigationEvidence(
      id: "service-\(service.instanceId)",
      kind: .service,
      occurredAt: service.startedAt,
      service: service.service,
      title: "Service instance started",
      detail: service.version.map { "Instance \(service.instanceId) started with image \($0)." } ?? "Instance \(service.instanceId) started.",
      attributes: ["instance_id": service.instanceId, "version": service.version ?? "unknown"]
    )
  }

  private static func alertEvidence(_ alert: OperationsAlert) -> GapInvestigationEvidence {
    GapInvestigationEvidence(
      id: "alert-\(alert.id)",
      kind: .alert,
      occurredAt: alert.openedAt,
      service: "operations",
      title: "Alert: \(alert.rule.replacingOccurrences(of: "_", with: " "))",
      detail: alert.summary,
      attributes: alert.evidence
    )
  }

  private static func isErrorSpan(_ span: TraceSpan) -> Bool {
    span.status.lowercased() == "error" || span.status.hasPrefix("5")
  }

}
