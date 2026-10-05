import Foundation
import Testing
@testable import SocialWire

@Suite("Sports Request Handoff")
@MainActor
struct SportsTopicModelTests {
    @Test("account changes reject a delayed catalog response")
    func accountSwitch() async throws {
        let topic = fixture()
        let request = Task { await topic.loadCatalog() }
        try await Task.sleep(for: .milliseconds(10))
        topic.bind(viewer: "did:plc:newviewer")
        await request.value
        #expect(topic.catalog == nil)
        #expect(topic.items.isEmpty)
    }

    @Test("expired continuation restarts page one atomically")
    func expiredCursor() async {
        let topic = fixture()
        await topic.load(language: "en")
        #expect(topic.page?.cursor == "expired")
        await topic.load(language: "en", cursor: "expired")
        #expect(topic.page?.generationId == "generation")
        #expect(topic.error == nil)
        #expect(!topic.isLoading)
    }

    private func fixture() -> SportsTopicModel {
        let auth = ATProtoOAuthService()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SportsFixtureURLProtocol.self]
        let gateway = SocialWireGatewayClient(auth: auth, baseURL: URL(string: "https://sports-fixture.invalid")!, urlSession: URLSession(configuration: configuration))
        let xrpc = XRPCClient(auth: auth, resolver: ATProtoResolver())
        return SportsTopicModel(gateway: gateway, xrpc: xrpc)
    }
}
