import Foundation
import Observation
#if os(iOS)
import QuillSocialUI
#endif

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
