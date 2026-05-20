import Testing
@testable import SocialWire

@Suite("PublicationService")
@MainActor
struct PublicationServiceTests {
    @Test("publication collections include standard.site namespaces")
    func publicationCollectionsIncludeStandardSiteNamespaces() {
        #expect(PublicationService.publicationCollections.contains("site.standard.publication"))
        #expect(PublicationService.publicationCollections.contains("com.standard.publication"))
    }

    @Test("content collections include documents and entries")
    func contentCollectionsIncludeDocumentsAndEntries() {
        #expect(PublicationService.contentCollections.contains("site.standard.document"))
        #expect(PublicationService.contentCollections.contains("com.standard.entry"))
    }

    @Test("public AppView uses Bluesky relay")
    func publicAppViewUsesBlueskyRelay() {
        #expect(PublicationService.publicAppView.absoluteString == "https://public.api.bsky.app/")
    }
}
