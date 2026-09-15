actor SkyreaderWarmingRecorder {
  private(set) var lookupCount = 0
  private(set) var feeds: [String] = []

  func recordLookup() { lookupCount += 1 }
  func recordFeed(_ url: String) { feeds.append(url) }
}
