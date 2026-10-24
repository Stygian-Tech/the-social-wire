import Foundation
import Observation

@MainActor
@Observable
final class SocialWorkspaceModel {
    private(set) var sessionID = UUID()
    @ObservationIgnored private var viewerDID: String?
    @ObservationIgnored private var pdsURL: URL?
    @ObservationIgnored private var tokenEndpoint: URL?
    @ObservationIgnored private var loginIdentity: UUID?

    func bind(session: AuthSession?, loginIdentity: UUID? = nil) {
        // Token rotation belongs to the same login. Rebuilding the view tree for it
        // would discard an open composer and its confirmed publication checkpoints.
        let activeLogin = session == nil ? nil : loginIdentity
        guard viewerDID != session?.did || pdsURL != session?.pdsURL
            || tokenEndpoint != session?.tokenEndpoint || self.loginIdentity != activeLogin else { return }
        viewerDID = session?.did
        pdsURL = session?.pdsURL
        tokenEndpoint = session?.tokenEndpoint
        self.loginIdentity = activeLogin
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
