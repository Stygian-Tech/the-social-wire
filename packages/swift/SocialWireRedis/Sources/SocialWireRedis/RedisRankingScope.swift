public enum RedisRankingScope: Sendable, Equatable {
  case global(feed: String)
  case viewerCircle(feed: String, viewerDid: String)
}
