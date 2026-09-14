struct WireInboxWorkBatch: Sendable {
  let events: [WireInboxEvent]
  let appliedPassiveEventCount: Int
  var nextRepositoryCursor: WireInboxRepository? = nil
}
