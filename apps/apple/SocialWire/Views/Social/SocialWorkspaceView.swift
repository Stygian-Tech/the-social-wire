import SwiftUI
#if os(iOS)
import QuillSocialUI
#endif

struct SocialWorkspaceView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.appAccentColor) private var accentColor
    @Binding private var destination: SocialDestination
    var onShowSidebar: (() -> Void)?
    private let navigation: SocialNavigationState
    @State private var showsAccountSettings = false
    @State private var composerContext: SocialComposerContext?

    init(
        destination: Binding<SocialDestination> = .constant(.timeline),
        navigation: SocialNavigationState = SocialNavigationState(),
        onShowSidebar: (() -> Void)? = nil
    ) {
        _destination = destination
        self.navigation = navigation
        self.onShowSidebar = onShowSidebar
    }

    private var socialViewerDID: String? {
        #if os(iOS)
        appModel.social.quill?.viewerDID ?? appModel.viewerDID
        #else
        appModel.viewerDID
        #endif
    }

    var body: some View {
        integratedWorkspace
            .task(id: socialViewerDID) {
                navigation.bind(viewerDID: socialViewerDID)
                appModel.social.proEntitlement.bind(viewerDID: appModel.viewerDID)
            }
            .onChange(of: appModel.viewerDID) { _, _ in
                navigation.bind(viewerDID: socialViewerDID)
                composerContext = nil
                showsAccountSettings = false
            }
            .sheet(isPresented: $showsAccountSettings) {
                NavigationStack {
                    ProfileView(onShowSocialProfile: { showsAccountSettings = false })
                }
            }
            .sheet(item: $composerContext) { context in
                SocialComposerView(client: appModel.social.client, replyRoot: context.replyRoot, replyParent: context.replyParent, quote: context.quote)
            }
    }

    @ViewBuilder private var integratedWorkspace: some View {
        #if os(iOS)
        if destination == .proTools {
            SocialProFeatureGate(entitlement: appModel.social.proEntitlement) {
                SocialProToolsView()
            }
        } else if let model = appModel.social.quill,
                  let quillDestination = QuillSocialDestination(rawValue: destination.rawValue) {
            QuillSocialWorkspace(model: model, navigation: navigation.quill,
                                 destination: quillDestination, accentColor: accentColor, onShowSidebar: onShowSidebar,
                                 onShowNotifications: { destination = .notifications },
                                 onShowSettings: { showsAccountSettings = true })
                .id(model.viewerDID)
        } else if appModel.viewerDID == nil {
            // Signed-out shell fixtures and the existing login flow retain their host shell.
            workspace
        } else {
            NavigationStack {
                ContentUnavailableView("Social Unavailable", systemImage: "exclamationmark.bubble",
                                       description: Text(appModel.social.quillInitializationError ?? "Social could not be initialized."))
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if let onShowSidebar { NewsSidebarButton(action: onShowSidebar) }
                        }
                        ToolbarItem(placement: .topBarTrailing) { accountButton }
                    }
            }
        }
        #else
        workspace
        #endif
    }

    @ViewBuilder private var workspace: some View {
        #if os(macOS)
        // The macOS tab shell does not supply the shared iOS/iPadOS app sidebar.
        NavigationSplitView {
            List {
                ForEach(SocialDestination.allCases.filter { !$0.requiresPro || SocialWireAPIEnvironment.proFeaturesReleased }) { item in
                    Button { destination = item } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(destination == item ? .isSelected : [])
                }
            }
            .navigationTitle("Social")
        } detail: {
            navigationStack
        }
        #else
        navigationStack
        #endif
    }

    private var navigationStack: some View {
        NavigationStack(path: selectedPath) {
            destinationView
                .navigationTitle(destination.title)
                .navigationDestination(for: SocialRoute.self, destination: routeView)
                .toolbar {
                    ToolbarItem(placement: sidebarLeadingPlacement) {
                        if let onShowSidebar { NewsSidebarButton(action: onShowSidebar) }
                    }
                    ToolbarItem(placement: .primaryAction) { accountButton }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Compose Post", systemImage: "square.and.pencil") { composerContext = .init() }
                    }
                }
        }
    }

    private var accountButton: some View {
        Button("Account", systemImage: "person.crop.circle") {
            showsAccountSettings = true
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("social-open-account")
    }

    private var sidebarLeadingPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Each sidebar destination keeps its own drill-down history.
    private var selectedPath: Binding<[SocialRoute]> {
        let selectedDestination = destination
        let contextID = navigation.contextID
        return Binding(
            get: { navigation.path(for: selectedDestination) },
            set: { navigation.setPath($0, for: selectedDestination, contextID: contextID) }
        )
    }

    @ViewBuilder private var destinationView: some View {
        switch destination {
        case .timeline:
            SocialTimelineView(model: appModel.social.timeline, navigate: navigate, compose: compose)
        case .explore:
            SocialExploreView(model: appModel.social.discovery, navigate: navigate)
        case .feeds:
            SocialFeedDirectoryView(model: appModel.social.catalog, navigate: navigate)
        case .notifications:
            SocialNotificationsView(model: appModel.social.notifications, navigate: navigate)
        case .messages:
            SocialMessagesView(model: appModel.social.messages)
        case .bookmarks:
            SocialBookmarksView(model: appModel.social.catalog, navigate: navigate)
        case .lists:
            SocialListsView(model: appModel.social.catalog, navigate: navigate)
        case .proTools:
            SocialProFeatureGate(entitlement: appModel.social.proEntitlement) {
                SocialProToolsView()
            }
        }
    }

    @ViewBuilder private func routeView(_ route: SocialRoute) -> some View {
        switch route {
        case .post(let uri):
            SocialThreadView(uri: uri, client: appModel.social.client, navigate: navigate, compose: compose)
        case .profile(let did):
            SocialProfileView(did: did, client: appModel.social.client, navigate: navigate)
        case .feed(let uri, let name):
            SocialFeedView(client: appModel.social.client, feedURI: uri, title: name, navigate: navigate, compose: compose)
        case .list(let uri, let name):
            SocialFeedView(client: appModel.social.client, listURI: uri, title: name, navigate: navigate, compose: compose)
        case .conversation:
            SocialMessagesView(model: appModel.social.messages)
        case .compose(let replyTo, let quote):
            Color.clear.onAppear {
                composerContext = .init(replyRoot: replyTo, replyParent: replyTo, quote: quote)
                var path = navigation.path(for: destination)
                if path.last == route {
                    path.removeLast()
                    navigation.setPath(path, for: destination, contextID: navigation.contextID)
                }
            }
        }
    }

    private func navigate(_ route: SocialRoute) {
        var path = navigation.path(for: destination)
        path.append(route)
        navigation.setPath(path, for: destination, contextID: navigation.contextID)
    }
    private func compose(_ root: SocialPostReference?, _ parent: SocialPostReference?, _ quote: SocialPostReference?) {
        composerContext = .init(replyRoot: root, replyParent: parent, quote: quote)
    }
}

private struct SocialComposerContext: Identifiable {
    let id = UUID()
    var replyRoot: SocialPostReference?
    var replyParent: SocialPostReference?
    var quote: SocialPostReference?
}
