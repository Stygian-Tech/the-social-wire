import Foundation

public extension OperationsStore {
  func investigateGap(id: String) async throws -> GapInvestigation? {
    guard let gap = try await fetchGap(id: id) else { return nil }
    let investigationWindow = GapInvestigationBuilder.window(for: gap)
    let events = try await listGapInvestigationEvents(
      startAt: investigationWindow.start,
      endAt: investigationWindow.end,
      limit: 500
    )
    let spans = try await listTraceSpans(
      startAt: investigationWindow.start,
      endAt: investigationWindow.end,
      limit: 250
    )
    let services = try await listServiceStates()
    let alerts = try await listAlerts(limit: 250)
    return GapInvestigationBuilder.build(
      gap: gap,
      events: events,
      spans: spans,
      services: services,
      alerts: alerts
    )
  }
}
