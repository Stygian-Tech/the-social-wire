#if os(iOS)
import Feeds
import Foundation
import Observation

@MainActor
@Observable
final class AppServices {
    typealias AppViewRequest = @Sendable (_ nsid: String, _ parameters: [String: String]) async throws -> Data
    typealias AppViewProcedure = @Sendable (_ nsid: String, _ body: Data) async throws -> Data
    typealias ChatProcedure = @Sendable (_ nsid: String, _ body: Data) async throws -> Data
    typealias FeedTimelineSourceFactory = @MainActor (PinnedFeed) -> any TimelineSource
    typealias EventRsvpUpdate = @Sendable (
        _ eventURI: String,
        _ eventCID: String,
        _ status: AtmoRsvpStatus?,
        _ existingRkey: String?
    ) async throws -> String?
    typealias StandardSiteRecordUpdate = @Sendable (
        _ targetURI: String,
        _ existingRecordURI: String?
    ) async throws -> String?
    typealias FollowUpdate = @Sendable (
        _ actorDID: String,
        _ existingRecordURI: String?
    ) async throws -> String?
    typealias LinkPreviewResolver = @Sendable (_ url: URL) async -> ComposerLinkPreview?
    typealias LabelerConfigurationUpdate = @Sendable (
        _ includesBluesky: Bool,
        _ additionalDIDs: [String]
    ) async -> Void
    typealias PreferencesUpdate = @Sendable (_ body: Data) async throws -> Void

    let timelineSource: any TimelineSource
    let appViewRequest: AppViewRequest
    let appViewProcedure: AppViewProcedure
    let chatRequest: AppViewRequest
    let chatProcedure: ChatProcedure
    let currentAccountDID: @Sendable () async throws -> String
    let activeLabelerDIDs: @Sendable () async throws -> [String]
    let updateLabelerConfiguration: LabelerConfigurationUpdate
    let preferencesRequest: @Sendable () async throws -> Data
    let preferencesUpdate: PreferencesUpdate
    let feedTimelineSource: FeedTimelineSourceFactory
    let pinnedFeedsSource: any PinnedFeedsSource
    let postThreadSource: any PostThreadSource
    let postActionSource: any PostActionSource
    let storySource: any StorySource
    let currentProfile: CurrentProfileModel
    let accountBadgeProfiles: AccountBadgeProfileStore
    let remoteVerifications = RemoteVerificationStore()
    let notificationBadge: NotificationBadgeModel
    let updateFollow: FollowUpdate
    let resolveLinkPreview: LinkPreviewResolver
    let updatePublicationSubscription: StandardSiteRecordUpdate
    let updateDocumentRecommend: StandardSiteRecordUpdate
    let updateEventRsvp: EventRsvpUpdate

    init(
        timelineSource: any TimelineSource,
        appViewRequest: @escaping AppViewRequest,
        appViewProcedure: @escaping AppViewProcedure,
        chatRequest: @escaping AppViewRequest,
        chatProcedure: @escaping ChatProcedure,
        currentAccountDID: @escaping @Sendable () async throws -> String,
        activeLabelerDIDs: @escaping @Sendable () async throws -> [String],
        updateLabelerConfiguration: @escaping LabelerConfigurationUpdate,
        preferencesRequest: @escaping @Sendable () async throws -> Data,
        preferencesUpdate: @escaping PreferencesUpdate,
        feedTimelineSource: @escaping FeedTimelineSourceFactory,
        pinnedFeedsSource: any PinnedFeedsSource,
        postThreadSource: any PostThreadSource,
        postActionSource: any PostActionSource,
        storySource: any StorySource,
        currentProfile: CurrentProfileModel,
        accountBadgeProfiles: AccountBadgeProfileStore,
        updateFollow: @escaping FollowUpdate,
        resolveLinkPreview: @escaping LinkPreviewResolver,
        updatePublicationSubscription: @escaping StandardSiteRecordUpdate,
        updateDocumentRecommend: @escaping StandardSiteRecordUpdate,
        updateEventRsvp: @escaping EventRsvpUpdate
    ) {
        self.timelineSource = timelineSource
        self.appViewRequest = appViewRequest
        self.appViewProcedure = appViewProcedure
        self.chatRequest = chatRequest
        self.chatProcedure = chatProcedure
        self.currentAccountDID = currentAccountDID
        self.activeLabelerDIDs = activeLabelerDIDs
        self.updateLabelerConfiguration = updateLabelerConfiguration
        self.preferencesRequest = preferencesRequest
        self.preferencesUpdate = preferencesUpdate
        self.feedTimelineSource = feedTimelineSource
        self.pinnedFeedsSource = pinnedFeedsSource
        self.postThreadSource = postThreadSource
        self.postActionSource = postActionSource
        self.storySource = storySource
        self.currentProfile = currentProfile
        self.accountBadgeProfiles = accountBadgeProfiles
        notificationBadge = NotificationBadgeModel(request: appViewRequest)
        self.updateFollow = updateFollow
        self.resolveLinkPreview = resolveLinkPreview
        self.updatePublicationSubscription = updatePublicationSubscription
        self.updateDocumentRecommend = updateDocumentRecommend
        self.updateEventRsvp = updateEventRsvp
    }
}

#endif
