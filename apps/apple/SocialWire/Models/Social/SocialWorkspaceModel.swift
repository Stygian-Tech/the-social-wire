import Foundation
import Observation

@MainActor
@Observable
final class SocialWorkspaceModel {
    private(set) var sessionID = UUID()
    @ObservationIgnored private var session: AuthSession?

    func bind(session: AuthSession?) {
        guard self.session != session else { return }
        self.session = session
        sessionID = UUID()
        timeline.reset()
        discovery.reset()
        notifications.reset()
        messages.reset()
        catalog.reset()
        proEntitlement.reset(viewerDID: session?.did)
    }

    let client: SocialWireSocialClient
    let timeline: SocialTimelineModel
    let discovery: SocialDiscoveryModel
    let notifications: SocialNotificationsModel
    let messages: SocialMessagesModel
    let catalog: SocialCatalogModel
    let proEntitlement: SocialProEntitlementModel

    init(xrpc: XRPCClient, publicationService: PublicationService, gateway: SocialWireGatewayClient) {
        let client = SocialWireSocialClient(xrpc: xrpc, publicationService: publicationService)
        self.client = client
        timeline = SocialTimelineModel(client: client)
        discovery = SocialDiscoveryModel(client: client)
        notifications = SocialNotificationsModel(client: client)
        messages = SocialMessagesModel(client: client)
        catalog = SocialCatalogModel(client: client)
        proEntitlement = SocialProEntitlementModel(gateway: gateway)
    }
}
