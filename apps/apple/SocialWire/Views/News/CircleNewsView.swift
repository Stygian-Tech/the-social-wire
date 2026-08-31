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
                    Text(appModel.circleCatalog?.subtitle ?? "Stories shared across your network")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

private struct CircleStoryCard: View {
    let story: CircleStory
    let onReadInApp: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thumbnailUrl = story.thumbnailUrl {
                CachedRemoteImage(urls: [URL(string: thumbnailUrl)].compactMap { $0 }, maxPixelSize: 1_000) {
                    Rectangle().fill(.quaternary)
                }
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipShape(.rect(cornerRadius: 16))
                .clipped()
                .accessibilityHidden(true)
            }

            CircleSharerStrip(sharers: story.sharers)

            Text(story.source.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let url = URL(string: story.canonicalUrl) {
                Link(story.title, destination: url)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .accessibilityHint("Opens the publisher's website")
            } else {
                Text(story.title).font(.title2.bold())
            }

            if let summary = story.summary, !summary.isEmpty {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                if let url = URL(string: story.canonicalUrl) {
                    Link(destination: url) {
                        Label("Open on Website", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: onReadInApp) {
                    Label("Read in App", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive, action: onHide) {
                    Label("Hide", systemImage: "eye.slash")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

private struct CircleSharerStrip: View {
    let sharers: [CircleSharer]

    var body: some View {
        if !sharers.isEmpty {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(sharers.prefix(4), id: \.identity.did) { sharer in
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
                    }
                }
                Text(sharerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var sharerSummary: String {
        let names = sharers.prefix(2).map {
            $0.identity.displayName?.isEmpty == false ? $0.identity.displayName! : $0.identity.handle
        }
        let context = sharers.contains { $0.relationship == "direct" } ? "in your network" : "one hop away"
        return "Shared by \(names.joined(separator: ", ")) · \(context)"
    }
}
