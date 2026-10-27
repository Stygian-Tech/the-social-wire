#if os(iOS)
import Feeds
import Foundation
@testable import QuillSocialUI

@MainActor
enum TestAppServices {
    static func make() -> AppServices {
        let request: AppServices.AppViewRequest = { _, _ in throw URLError(.notConnectedToInternet) }
        let procedure: AppServices.AppViewProcedure = { _, _ in throw URLError(.notConnectedToInternet) }
        let timeline = ATProtoTimelineSource { _ in throw URLError(.notConnectedToInternet) }
        return AppServices(
            timelineSource: timeline,
            appViewRequest: request, appViewProcedure: procedure,
            chatRequest: request, chatProcedure: procedure,
            currentAccountDID: { "did:plc:fixture" },
            activeLabelerDIDs: { [] },
            updateLabelerConfiguration: { _, _ in },
            preferencesRequest: { throw URLError(.notConnectedToInternet) },
            preferencesUpdate: { _ in },
            feedTimelineSource: { _ in timeline },
            pinnedFeedsSource: InMemoryPinnedFeedsSource(),
            postThreadSource: ATProtoPostThreadSource { _ in throw URLError(.notConnectedToInternet) },
            postActionSource: ATProtoPostActionSource(
                sessionDID: { "did:plc:fixture" }, procedure: procedure
            ),
            storySource: ATProtoStorySource(
                sessionDID: { "did:plc:fixture" },
                profileRequest: { _ in throw URLError(.notConnectedToInternet) },
                followsRequest: { _ in throw URLError(.notConnectedToInternet) },
                recordsRequest: { _ in throw URLError(.notConnectedToInternet) }
            ),
            currentProfile: CurrentProfileModel { throw URLError(.notConnectedToInternet) },
            accountBadgeProfiles: AccountBadgeProfileStore(
                profileLoader: { _ in throw URLError(.notConnectedToInternet) },
                labelerLoader: { _ in throw URLError(.notConnectedToInternet) }
            ),
            updateFollow: { _, _ in nil },
            resolveLinkPreview: { _ in nil },
            updatePublicationSubscription: { _, _ in nil },
            updateDocumentRecommend: { _, _ in nil },
            updateEventRsvp: { _, _, _, _ in nil }
        )
    }
}

#endif
