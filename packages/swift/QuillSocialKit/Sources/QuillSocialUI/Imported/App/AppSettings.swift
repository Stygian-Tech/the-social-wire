#if os(iOS)
import SwiftData

@Model
final class AppSettings {
    var videoPlaybackPolicyRawValue: String = VideoPlaybackPolicy.tapToPlay.rawValue
    var key: String = "app-settings"
    var stockChartStyleRawValue: String = StockChartStyle.line.rawValue
    var themeColorRawValue: String = AppThemeColor.blue.rawValue
    var requiresAltText: Bool = false
    var allowsComposerAltTextGeneration: Bool = true
    var allowsViewerAltTextGeneration: Bool = true
    var trustedVerifierDIDs: [String] = []
    var includesBlueskyVerification: Bool = true
    var verifiesJerry: Bool = true
    var contentProviderProxy: String = ContentProviderPreferences.blueskyProxy
    var includesBlueskyModeration: Bool = true
    var additionalLabelerDIDs: [String] = []

    init(
        themeColor: AppThemeColor = .blue,
        requiresAltText: Bool = false,
        allowsComposerAltTextGeneration: Bool = true,
        allowsViewerAltTextGeneration: Bool = true,
        trustedVerifierDIDs: [String] = [],
        includesBlueskyVerification: Bool = true,
        verifiesJerry: Bool = true,
        contentProviderProxy: String = ContentProviderPreferences.blueskyProxy,
        includesBlueskyModeration: Bool = true,
        additionalLabelerDIDs: [String] = []
    ) {
        key = "app-settings"
        themeColorRawValue = themeColor.rawValue
        self.requiresAltText = requiresAltText
        self.allowsComposerAltTextGeneration = allowsComposerAltTextGeneration
        self.allowsViewerAltTextGeneration = allowsViewerAltTextGeneration
        self.trustedVerifierDIDs = trustedVerifierDIDs
        self.includesBlueskyVerification = includesBlueskyVerification
        self.verifiesJerry = verifiesJerry
        self.contentProviderProxy = contentProviderProxy
        self.includesBlueskyModeration = includesBlueskyModeration
        self.additionalLabelerDIDs = additionalLabelerDIDs
    }

    var videoPlaybackPolicy: VideoPlaybackPolicy {
        get { VideoPlaybackPolicy(rawValue: videoPlaybackPolicyRawValue) ?? .tapToPlay }
        set { videoPlaybackPolicyRawValue = newValue.rawValue }
    }

    var themeColor: AppThemeColor {
        get { AppThemeColor(rawValue: themeColorRawValue) ?? .blue }
        set { themeColorRawValue = newValue.rawValue }
    }

    var stockChartStyle: StockChartStyle {
        get { StockChartStyle(rawValue: stockChartStyleRawValue) ?? .line }
        set { stockChartStyleRawValue = newValue.rawValue }
    }

    var usesBlueskyContentProvider: Bool {
        contentProviderProxy == ContentProviderPreferences.blueskyProxy
    }

    var canDisableBlueskyVerification: Bool {
        !usesBlueskyContentProvider
    }
}

#endif
