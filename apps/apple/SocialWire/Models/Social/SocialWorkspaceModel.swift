import Observation
#if os(iOS)
import QuillSocialUI
#endif

@MainActor
@Observable
final class SocialWorkspaceModel {
    let client: SocialWireSocialClient
    let timeline: SocialTimelineModel
    let discovery: SocialDiscoveryModel
    let notifications: SocialNotificationsModel
    let messages: SocialMessagesModel
    let catalog: SocialCatalogModel
    let proEntitlement: SocialProEntitlementModel
    #if os(iOS)
    private(set) var quill: QuillSocialModel?
    private(set) var quillInitializationError: String?
    #endif

    init(xrpc: XRPCClient, publicationService: PublicationService, gateway: SocialWireGatewayClient, viewerDID: String? = nil) {
        let client = SocialWireSocialClient(xrpc: xrpc, publicationService: publicationService)
        self.client = client
        timeline = SocialTimelineModel(client: client)
        discovery = SocialDiscoveryModel(client: client)
        notifications = SocialNotificationsModel(client: client)
        messages = SocialMessagesModel(client: client)
        catalog = SocialCatalogModel(client: client)
        proEntitlement = SocialProEntitlementModel(gateway: gateway)
        #if os(iOS)
        if let viewerDID {
            do {
                quill = try QuillSocialModel(configuration: QuillSocialTransport.configuration(xrpc: xrpc, viewerDID: viewerDID))
            } catch {
                quill = nil
                quillInitializationError = error.localizedDescription
            }
        } else {
            quill = nil
        }
        #endif
    }

    #if os(iOS) && DEBUG
    func configureQuillFixture() throws {
        quill = try QuillSocialFixtures.model()
    }
    #endif
}
