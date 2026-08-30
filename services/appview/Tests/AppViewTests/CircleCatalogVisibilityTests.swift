import Testing
import WireCore

@testable import AppView

@Suite("Your Circle catalog visibility")
struct CircleCatalogVisibilityTests {
  private let wireCatalog = WireFeedCatalog(
    enabled: true,
    available: true,
    supportedLanguages: ["en"],
    latestGenerationID: "wire-generation",
    generatedAt: nil
  )

  @Test("API-only mode does not advertise web navigation")
  func apiOnly() {
    let response = CircleDiscoveryService.catalogResponse(
      wireCatalog: wireCatalog,
      enabled: CircleDiscoveryMode.api.isVisible
    )
    #expect(!response.enabled)
    #expect(response.available)
  }

  @Test("visible mode advertises the authenticated destination")
  func visible() {
    let response = CircleDiscoveryService.catalogResponse(
      wireCatalog: wireCatalog,
      enabled: CircleDiscoveryMode.visible.isVisible
    )
    #expect(response.enabled)
    #expect(response.supportedLanguages == ["en"])
  }
}
