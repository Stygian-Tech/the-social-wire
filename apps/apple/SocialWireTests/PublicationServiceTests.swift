import Testing
@testable import SocialWire

@Suite("PublicationService")
@MainActor
struct PublicationServiceTests {
    @Test("public AppView uses Bluesky relay")
    func publicAppViewUsesBlueskyRelay() {
        #expect(PublicationService.publicAppView.absoluteString == "https://public.api.bsky.app")
    }
}
