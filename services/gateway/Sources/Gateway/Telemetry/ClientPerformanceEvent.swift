enum ClientPerformanceEvent: String, Codable, Sendable {
  case cachedFeedPaint = "cached_feed_paint"
  case uncachedFeedPaint = "uncached_feed_paint"
  case feedSwitch = "feed_switch"
  case freshMerge = "fresh_merge"
  case feedError = "feed_error"
}
