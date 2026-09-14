/// Rotation order is stable: one bounded table sample every 30 seconds, a full pass in five minutes.
enum DatabaseExpiryTelemetryTable: String, CaseIterable, Sendable {
  case contentItems = "content_items"
  case wireItems = "wire_items"
  case wireItemAliases = "wire_item_aliases"
  case wireRankGenerations = "wire_rank_generations"
  case circleGraphSnapshots = "appview_circle_graph_snapshots"
  case circleEditionCache = "appview_circle_edition_cache"
  case metricRollups = "operations_metric_rollups"
  case changeEvents = "operations_change_events"
  case appviewInbox = "appview_ingestion_inbox"
  case wireInbox = "wire_ingestion_inbox"
}
