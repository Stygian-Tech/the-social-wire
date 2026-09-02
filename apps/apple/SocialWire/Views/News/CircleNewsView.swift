import SwiftUI

struct CircleNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let sceneModel: NewsSceneModel
    @State private var lastHiddenStory: CircleStory?

    private var usesPersistentDetail: Bool { horizontalSizeClass != .compact }

    var body: some View {
        Group {
            if usesPersistentDetail {
                HStack(spacing: 0) {
                    editorialCanvas
                        .frame(minWidth: 360, idealWidth: 560, maxWidth: 680)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                editorialCanvas
            }
        }
        .navigationTitle("Your Circle")
        .task {
            if appModel.circleEdition == nil {
                await appModel.loadCircleEdition()
            }
        }
        .overlay(alignment: .bottom) {
            if let lastHiddenStory {
                HStack(spacing: 12) {
                    Text("Story hidden")
                    Button("Undo") {
                        self.lastHiddenStory = nil
                        Task { await appModel.setCircleStory(lastHiddenStory, hidden: false) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .capsule)
                .padding()
            }
        }
    }

    private var editorialCanvas: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("FROM PEOPLE YOU FOLLOW")
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text("Your Circle")
                        .font(.largeTitle.bold())
                }

                if let message = appModel.circleErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if appModel.visibleCircleStories.isEmpty, appModel.isLoadingCircle {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if appModel.visibleCircleStories.isEmpty {
                    ContentUnavailableView(
                        "Nothing from Your Circle Yet",
                        systemImage: "person.2.wave.2",
                        description: Text("New stories will appear as people in your network share them.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(appModel.visibleCircleStories, id: \.storyId) { story in
                        CircleStoryCard(
                            story: story,
                            onReadInApp: { openInReader(story) },
                            onHide: { hide(story) }
                        )
                        .onAppear {
                            guard story.storyId == appModel.visibleCircleStories.last?.storyId,
                                  let cursor = appModel.circleEdition?.moreCursor
                            else { return }
                            Task { await appModel.loadCircleEdition(cursor: cursor) }
                        }
                    }
                    if appModel.isLoadingCircle {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await appModel.loadCircleEdition() }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = appModel.selectedEntry {
            EntryDetailView(entry: entry)
        } else {
            ContentUnavailableView(
                "Select a Story",
                systemImage: "doc.text",
                description: Text("Open a story here or continue to the publisher's website.")
            )
        }
    }

    private func openInReader(_ story: CircleStory) {
        appModel.selectCircleStory(story)
        if !usesPersistentDetail {
            sceneModel.navigate(to: .entry(id: story.storyId), in: .circle)
        }
    }

    private func hide(_ story: CircleStory) {
        lastHiddenStory = story
        Task { await appModel.setCircleStory(story, hidden: true) }
    }
}

struct CircleStoryCard: View {
    let story: CircleStory
    let onReadInApp: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thumbnailUrl = story.thumbnailUrl {
                NewsStoryImage(
                    urls: [URL(string: thumbnailUrl)].compactMap { $0 },
                    height: 200
                )
            }

            CircleSharerStrip(
                sharers: story.sharers,
                totalCount: story.sharerCount ?? story.sharers.count
            )

            Text(story.source.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let url = URL(string: story.canonicalUrl) {
                Link(destination: url) {
                    Text(story.title)
                        .font(.title3.bold())
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityHint("Opens the publisher's website")
            } else {
                Text(story.title).font(.title3.bold())
            }

            if let summary = story.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NewsStoryActions(
                websiteURL: URL(string: story.canonicalUrl),
                onReadInApp: onReadInApp,
                onHide: onHide
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { Divider() }
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .contain)
    }
}

private struct CircleSharerStrip: View {
    let sharers: [CircleSharer]
    let totalCount: Int

    var body: some View {
        if !sharers.isEmpty {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(Array(visibleSharers.enumerated()), id: \.element.sourceUri) { index, sharer in
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let raw = sharer.identity.avatarUrl, let url = URL(string: raw) {
                                    CachedRemoteImage(urls: [url], maxPixelSize: 80) {
                                        Circle().fill(.quaternary)
                                    }
                                    .scaledToFill()
                                } else {
                                    Circle().fill(.quaternary)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .clipShape(.circle)
                            .overlay { Circle().stroke(.background, lineWidth: 2) }

                            if sharer.relationship == "one_hop" {
                                Text("+1")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.primary)
                                    .padding(.horizontal, 2)
                                    .background(.background, in: Capsule())
                                    .overlay { Capsule().stroke(.quaternary, lineWidth: 1) }
                                    .offset(x: 2, y: 2)
                                    .accessibilityHidden(true)
                            }
                        }
                        .zIndex(Double(visibleSharers.count - index))
                    }
                }
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private var visibleSharers: [CircleSharer] {
        Array(sharers.prefix(5))
    }

    private var accessibilitySummary: String {
        let accounts = visibleSharers.map { sharer in
            let name = sharer.identity.displayName?.isEmpty == false
                ? sharer.identity.displayName!
                : sharer.identity.handle
            return sharer.relationship == "one_hop" ? "\(name), one hop away" : name
        }
        let remainder = overflowCount > 0 ? ", and \(overflowCount) more accounts" : ""
        return "Shared by \(accounts.joined(separator: ", "))\(remainder)"
    }

    private var overflowCount: Int {
        max(0, totalCount - visibleSharers.count)
    }
}
