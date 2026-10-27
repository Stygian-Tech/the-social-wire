#if os(iOS)
import CryptoKit
import Feeds
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
public final class QuillSocialModel {
    public let viewerDID: String
    let configuration: QuillSocialConfiguration
    let services: AppServices
    let homeFeeds: HomeFeedsModel
    let pinnedFeeds: PinnedFeedsModel
    let stories: StoryModel
    let threadPositions: ThreadPositionStore
    let settingsContainer: ModelContainer

    public var unreadNotificationCount: Int { services.notificationBadge.unreadCount }

    public func refreshNotificationBadge() async {
        await services.notificationBadge.refresh()
    }

    public init(configuration: QuillSocialConfiguration, inMemorySettings: Bool = false) throws {
        viewerDID = configuration.viewerDID
        self.configuration = configuration
        let viewerKey = SHA256.hash(data: Data(viewerDID.utf8)).map { String(format: "%02x", $0) }.joined()
        let storage = ModelConfiguration(
            "SocialWireSocial-\(viewerKey)", isStoredInMemoryOnly: inMemorySettings, cloudKitDatabase: .none)
        settingsContainer = try ModelContainer(for: AppSettings.self, configurations: storage)
        let context = settingsContainer.mainContext
        let settings: AppSettings
        if let existing = try context.fetch(FetchDescriptor<AppSettings>()).first {
            settings = existing
        } else {
            settings = AppSettings()
            context.insert(settings)
            try context.save()
        }
        ContentProviderPreferences.saveProvider(proxy: settings.contentProviderProxy)
        ContentProviderPreferences.saveModeration(
            includesBluesky: settings.includesBlueskyModeration, additionalLabelerDIDs: settings.additionalLabelerDIDs)
        let services = QuillSocialServicesFactory.make(configuration: configuration)
        self.services = services
        let timeline = TimelineModel(source: services.timelineSource)
        homeFeeds = HomeFeedsModel(homeTimeline: timeline, sourceFactory: services.feedTimelineSource)
        pinnedFeeds = PinnedFeedsModel(source: services.pinnedFeedsSource)
        stories = StoryModel(source: services.storySource)
        threadPositions = ThreadPositionStore(source: services.postThreadSource)
    }
}
#endif
