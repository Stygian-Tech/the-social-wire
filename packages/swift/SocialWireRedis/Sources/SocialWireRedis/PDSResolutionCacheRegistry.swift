public actor PDSResolutionCacheRegistry {
  public static let shared = PDSResolutionCacheRegistry()

  private var installed: (any PDSResolutionCache)?

  public init() {}

  public func install(_ cache: (any PDSResolutionCache)?) {
    installed = cache
  }

  public func current() -> any PDSResolutionCache {
    installed ?? InMemoryPDSResolutionCache.shared
  }
}
