import SwiftUI

struct PublicationsPaneView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Binding var showingNewFolder: Bool
    @Binding var showingAddPublication: Bool
    var onPublicationTap: ((DiscoveredPublication) -> Void)? = nil
    var onSavedLinkTap: ((MergedLatrSave) -> Void)? = nil
    @State private var refreshFeedback = 0

    var body: some View {
        @Bindable var model = appModel

        Group {
            switch appModel.readerListSource {
            case .readLater, .archive:
                SavedLinksListContent(onSavedLinkTap: onSavedLinkTap)
            case .subscribed:
                List(selection: $model.selectedSidebar) {
                    SubscribedPublicationSidebarTree(
                        showingNewFolder: $showingNewFolder,
                        showingAddPublication: $showingAddPublication,
                        onPublicationTap: onPublicationTap
                    )
                }
                .readerListCanvas()
            case .following:
                List(selection: $model.selectedSidebar) {
                    FollowingPublicationSidebarTree(onPublicationTap: onPublicationTap)
                }
                .readerListCanvas()
            }
        }
        .refreshable {
            switch appModel.readerListSource {
            case .readLater, .archive:
                await appModel.refreshSavedLinks()
            case .subscribed, .following:
                await appModel.refreshSidebarProjection()
            }
            refreshFeedback += 1
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: refreshFeedback)
    }
}
