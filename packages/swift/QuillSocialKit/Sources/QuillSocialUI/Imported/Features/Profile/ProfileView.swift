#if os(iOS)
import Feeds
import SwiftUI

struct ProfileView: View {
    var actor: String?

    @Environment(\.hostAccountSettings) private var hostAccountSettings
    @Environment(AppServices.self) private var services
    @Environment(StoryModel.self) private var stories
    @State private var model = ProfileModel()
    @State private var selectedSection = ProfileSection.posts
    @State private var showsSettings = false
    @State private var showsStickyIdentity = false

    var body: some View {
        Group {
            if let profile = model.profile {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                                ProfileHeaderView(
                                    profile: profile,
                                    links: model.links,
                                    germAvailability: model.availableGermDM,
                                    storyItem: activeStory(for: profile.did),
                                    stories: stories,
                                    topSafeAreaInset: geometry.safeAreaInsets.top,
                                    isCurrentProfile: model.isCurrentProfile,
                                    isFollowing: model.isFollowing,
                                    isUpdatingFollow: model.isUpdatingFollow,
                                    followErrorGeneration: model.followErrorGeneration,
                                    onFollow: {
                                        Task { await model.toggleFollow(services: services) }
                                    }
                                )

                                AccountLabelsView(author: profile.timelineAuthor)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal)
                                    .padding(.bottom, 2)

                                Section {
                                    selectedContent
                                        .padding(.top, 10)
                                } header: {
                                    sectionPicker
                                }
                        }
                    }
                    .accessibilityIdentifier("social-profile-scroll")
                    .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                        scrollGeometry.visibleRect.minY > 150
                    } action: { _, isPastIdentity in
                        showsStickyIdentity = isPastIdentity
                    }
                    .refreshable { await refreshSelectedContent() }
                }
            } else if model.didFail {
                ContentUnavailableView(
                    "Profile Unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            } else {
                ProgressView("Loading Profile")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if showsStickyIdentity, let profile = model.profile {
                ToolbarItem(placement: .principal) {
                    ProfileStickyIdentityView(profile: profile)
                        .accessibilityIdentifier("social-profile-sticky-identity")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            if model.isCurrentProfile {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        if let hostAccountSettings {
                            hostAccountSettings()
                        } else {
                            showsSettings = true
                        }
                    }
                    .sensoryFeedback(.selection, trigger: showsSettings)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: showsStickyIdentity)
        .sheet(isPresented: $showsSettings) {
            NavigationStack { ProfileSettingsView() }
        }
        .videoPlaybackViewport()
        .task {
            async let profileLoad: Void = model.load(actor: actor, services: services)
            async let storyLoad: Void = stories.load()
            _ = await (profileLoad, storyLoad)
            await model.timeline(for: selectedSection)?.load()
        }
        .task(id: selectedSection) {
            await model.timeline(for: selectedSection)?.load()
        }
        .sensoryFeedback(.selection, trigger: selectedSection)
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.availableSections) { section in
                    Button(section.rawValue) {
                        selectedSection = section
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(selectedSection == section ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled(false)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .posts, .replies, .media, .likes:
            timelineContent
        case .reviews:
            externalContent(model.reviews, section: .reviews, symbol: "star.bubble")
        case .reading:
            externalContent(model.reading, section: .reading, symbol: "books.vertical")
        case .semble:
            externalContent(model.sembleCollections, section: .semble, symbol: "rectangle.stack")
        case .publications:
            publicationContent
        case .lists:
            resourceContent(model.lists, emptyTitle: "No Lists", symbol: "list.bullet")
        case .starterPacks:
            resourceContent(model.starterPacks, emptyTitle: "No Starter Packs", symbol: "person.3")
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if let timeline = model.timeline(for: selectedSection) {
            if timeline.posts.isEmpty, timeline.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if timeline.posts.isEmpty {
                ContentUnavailableView("No \(selectedSection.rawValue)", systemImage: "text.bubble")
                    .padding(.vertical, 40)
            } else {
                ForEach(timeline.posts) { post in
                    TimelinePostRow(post: post)
                        .padding(.horizontal)
                    Divider().padding(.leading, 68)
                }
                Color.clear
                    .frame(height: 1)
                    .task(id: "\(timeline.posts.last?.id ?? ""):\(timeline.paginationRevision)") {
                        guard timeline.canLoadMore, let lastPost = timeline.posts.last else { return }
                        await timeline.loadMore(after: lastPost)
                    }
            }
        }
    }

    @ViewBuilder
    private var publicationContent: some View {
        if model.publications.isEmpty {
            ContentUnavailableView("No Publications", systemImage: "newspaper")
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(model.publications) { publication in
                    ProfilePublicationCard(publication: publication)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    @ViewBuilder
    private func externalContent(_ items: [ProfileModel.ExternalItem], section: ProfileSection, symbol: String) -> some View {
        switch model.externalState(for: section) {
        case .loading:
            ProgressView("Loading \(section.rawValue)")
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        case .empty:
            ContentUnavailableView("No \(section.rawValue)", systemImage: symbol)
                .padding(.vertical, 40)
        case .failed:
            ContentUnavailableView {
                Label("\(section.rawValue) Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text("The Social Wire couldn’t load this collection.")
            } actions: {
                Button("Try Again") { Task { await model.retryExternalSection(section) } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 40)
        case .populated:
            externalItems(items, symbol: symbol)
        }
    }

    private func externalItems(_ items: [ProfileModel.ExternalItem], symbol: String) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    if let imageURL = item.imageURL {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: symbol)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 64, height: 88)
                        .clipShape(.rect(cornerRadius: 10))
                    } else {
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.subheadline)
                                .lineLimit(4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func resourceContent(
        _ resources: [ProfileModel.NamedResource],
        emptyTitle: LocalizedStringKey,
        symbol: String
    ) -> some View {
        if resources.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: symbol)
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(resources) { resource in
                    HStack(spacing: 12) {
                        AsyncImage(url: resource.avatarURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: symbol).foregroundStyle(.secondary)
                        }
                        .frame(width: 44, height: 44)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                        .clipShape(.rect(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.name).font(.headline)
                            if let description = resource.description {
                                Text(description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding()
                    Divider().padding(.leading, 72)
                }
            }
        }
    }

    private func activeStory(for did: String) -> StoryFeedItem? {
        stories.items.first { item in
            item.author.did == did && !item.isCurrentUser && !item.stories.isEmpty
        }
    }

    private func refreshSelectedContent() async {
        if [.reviews, .reading, .semble].contains(selectedSection) {
            await model.retryExternalSection(selectedSection)
        } else {
            await model.timeline(for: selectedSection)?.refreshVisibleContent()
        }
    }
}

#endif
