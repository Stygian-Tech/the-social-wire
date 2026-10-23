import SwiftUI

struct SocialWorkspaceView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @AppStorage("the-social-wire.social-destination.v1") private var storedDestination = SocialDestination.timeline.rawValue
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var path: [SocialRoute] = []
    @State private var destination = SocialDestination.timeline
    @State private var composerContext: SocialComposerContext?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List {
                ForEach(SocialDestination.allCases) { item in
                    Button { destination = item; compactColumn = .detail } label: {
                        HStack {
                            Label(item.title, systemImage: item.systemImage)
                            Spacer()
                            if item.requiresPro && !appModel.social.proEntitlement.isPro {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityLabel("Requires Social Wire Pro")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(destination == item ? Color.accentColor.opacity(0.12) : Color.clear)
                }
            }
            .navigationTitle("Social")
        } detail: {
            NavigationStack(path: $path) {
                destinationView
                    .navigationTitle(destination.title)
                    .navigationDestination(for: SocialRoute.self, destination: routeView)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Compose Post", systemImage: "square.and.pencil") { composerContext = .init() }
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            destination = SocialDestination(rawValue: storedDestination) ?? .timeline
            appModel.social.proEntitlement.bind(viewerDID: appModel.viewerDID)
        }
        .onChange(of: destination) { _, value in
            // Pro access and Pro navigation are intentionally not persisted.
            if !value.requiresPro { storedDestination = value.rawValue }
        }
        .sheet(item: $composerContext) { context in
            SocialComposerView(client: appModel.social.client, replyRoot: context.replyRoot, replyParent: context.replyParent, quote: context.quote)
        }
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
            Color.clear.onAppear { composerContext = .init(replyRoot: replyTo, replyParent: replyTo, quote: quote); path.removeLast() }
        }
    }

    private func navigate(_ route: SocialRoute) { path.append(route) }
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
