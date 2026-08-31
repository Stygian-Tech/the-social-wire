actor WireDNSResolverAdmission {
  private let maximumConcurrentResolutions: Int
  private var activeResolutions = 0

  init(maximumConcurrentResolutions: Int = 8) {
    self.maximumConcurrentResolutions = max(maximumConcurrentResolutions, 1)
  }

  func acquire() -> Bool {
    guard activeResolutions < maximumConcurrentResolutions else { return false }
    activeResolutions += 1
    return true
  }

  func release() {
    precondition(activeResolutions > 0)
    activeResolutions -= 1
  }

  func activeCount() -> Int { activeResolutions }
}
