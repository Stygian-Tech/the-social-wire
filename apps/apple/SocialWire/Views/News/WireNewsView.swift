import SwiftUI

/// Editorial presentation backed by the edition contract with ranked-list fallback.
struct WireNewsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let sceneModel: NewsSceneModel

    private var usesPersistentDetail: Bool {
        horizontalSizeClass != .compact
    }

    var body: some View {
        Group {
            if usesPersistentDetail {
                HStack(spacing: 0) {
                    editorialCanvas
                        .frame(minWidth: 360, idealWidth: 520, maxWidth: 620)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                editorialCanvas
            }
        }
        .navigationTitle("The Wire")
        .task {
            if appModel.readerListSource != .wire {
                appModel.selectReaderListSource(.wire)
            }
            if appModel.wireEdition == nil || appModel.entries.isEmpty {
                await appModel.loadWireEdition()
            }
        }
    }

    private var editorialCanvas: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                masthead

                if let notice = appModel.wireFeedNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(notice)
                }

                if appModel.entries.isEmpty, appModel.isLoadingEntries {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if appModel.entries.isEmpty {
                    ContentUnavailableView(
                        appModel.wireFeedLoadFailed ? "The Wire Is Unavailable" : "No Stories Yet",
                        systemImage: appModel.wireFeedLoadFailed ? "wifi.exclamationmark" : "newspaper"
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    WireLeadStoryCard(entry: appModel.entries[0]) {
                        openInReader(appModel.entries[0])
                    }

                    let supporting = Array(appModel.entries.dropFirst().prefix(4))
                    if !supporting.isEmpty {
                        WireSectionHeader(title: "Top Stories")
                        LazyVGrid(
                            columns: [GridItem(
                                dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: 280),
                                spacing: 18
                            )],
                            alignment: .leading,
                            spacing: 18
                        ) {
                            ForEach(supporting) { entry in
                                WireStoryCard(entry: entry) {
                                    openInReader(entry)
                                }
                            }
                        }
                    }

                    if let edition = appModel.wireEdition {
                        editionSections(edition)
                    }

                    let latest = Array(appModel.entries.dropFirst(5))
                    if !latest.isEmpty {
                        WireSectionHeader(title: "Latest")
                        ForEach(latest) { entry in
                            WireStoryRow(entry: entry) {
                                openInReader(entry)
                            }
                            .onAppear {
                                guard entry.id == latest.last?.id else { return }
                                Task {
                                    await appModel.loadMoreSelectedFeedIfNeeded(
                                        triggeredByEntryId: entry.entryId
                                    )
                                }
                            }
                        }
                    }

                    if appModel.isLoadingMoreEntries {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .refreshable {
            await appModel.loadWireEdition()
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("THE SOCIAL WIRE")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Text("The Wire")
                .font(.largeTitle.bold())
        }
        .accessibilityElement(children: .combine)
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

    private func openInReader(_ entry: EntryListItem) {
        Task {
            await appModel.selectEntry(entry)
            guard let selected = appModel.selectedEntry, selected.entryId == entry.entryId else { return }
            if !usesPersistentDetail {
                sceneModel.navigate(to: .entry(id: selected.entryId), in: .wire)
            }
        }
    }

    @ViewBuilder
    private func editionSections(_ edition: WireEditionPage) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: appModel.entries.map { ($0.entryId, $0) })
        let trending = edition.trendingStoryIds.compactMap { byID[$0] }
        if !trending.isEmpty {
            WireEditorialRail(title: "Trending", entries: trending, onOpen: openInReader)
        }

        ForEach(edition.storyRails, id: \.id) { rail in
            let stories = rail.storyIds.compactMap { byID[$0] }
            if !stories.isEmpty {
                WireEditorialRail(title: rail.title, entries: stories, onOpen: openInReader)
            }
        }

        if !edition.publicationSpotlights.isEmpty {
            WireSectionHeader(title: "Publication Spotlights")
            ForEach(edition.publicationSpotlights, id: \.id) { spotlight in
                VStack(alignment: .leading, spacing: 10) {
                    Text(spotlight.publication.displayName)
                        .font(.title3.bold())
                    ForEach(spotlight.storyIds.compactMap { byID[$0] }) { story in
                        WireStoryRow(entry: story) { openInReader(story) }
                    }
                }
            }
        }

        if !edition.people.isEmpty {
            WireSectionHeader(title: "People in the News")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(edition.people, id: \.did) { person in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.displayName).font(.headline)
                            Text("@\(person.handle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(.thinMaterial, in: .rect(cornerRadius: 14))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct WireEditorialRail: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let entries: [EntryListItem]
    let onOpen: (EntryListItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WireSectionHeader(title: title)
            ScrollView(.horizontal) {
                // These bounded editorial rails must measure every card's height;
                // a lazy stack can clip taller cards after a horizontal swipe.
                HStack(alignment: .top, spacing: 16) {
                    ForEach(entries) { entry in
                        WireStoryCard(entry: entry) { onOpen(entry) }
                            .containerRelativeFrame(.horizontal) { width, _ in
                                let count = dynamicTypeSize.isAccessibilitySize
                                    ? 1 : max(1, ((width + 16) / 296).rounded(.down))
                                return (width - 16 * (count - 1)) / count
                            }
                            .accessibilityIdentifier("wire-card-\(entry.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct WireLeadStoryCard: View {
    let entry: EntryListItem
    let onReadInApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WireStoryImage(entry: entry, height: 220)
            WireSourceLine(entry: entry)
            websiteTitle
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NewsStoryActions(websiteURL: entry.originalUrl.flatMap(URL.init(string:)), onReadInApp: onReadInApp)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var websiteTitle: some View {
        if let url = entry.originalUrl.flatMap(URL.init(string:)) {
            Link(destination: url) {
                Text(entry.title)
                    .font(.title2.bold())
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
            }
            .accessibilityHint("Opens the publisher's website")
        } else {
            Text(entry.title)
                .font(.title2.bold())
        }
    }
}

struct WireStoryCard: View {
    let entry: EntryListItem
    let onReadInApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WireStoryImage(entry: entry, height: 150)
            WireSourceLine(entry: entry)
            if let url = entry.originalUrl.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityHint("Opens the publisher's website")
            } else {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(3)
            }
            NewsStoryActions(websiteURL: entry.originalUrl.flatMap(URL.init(string:)), onReadInApp: onReadInApp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .contain)
    }
}

struct WireStoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: EntryListItem
    let onReadInApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                if !dynamicTypeSize.isAccessibilitySize,
                   !ThumbnailImageURLAttempts.candidates(
                       primary: entry.thumbnailUrl, fallback: entry.thumbnailFallbackUrl
                   ).isEmpty {
                    WireStoryImage(entry: entry, height: 72)
                        .frame(width: 80)
                }
                VStack(alignment: .leading, spacing: 5) {
                    WireSourceLine(entry: entry)
                    if let url = entry.originalUrl.flatMap(URL.init(string:)) {
                        Link(destination: url) {
                            Text(entry.title)
                                .font(.headline)
                                .foregroundStyle(Color.primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .accessibilityHint("Opens the publisher's website")
                    } else {
                        Text(entry.title)
                            .font(.headline)
                            .lineLimit(3)
                    }
                    Text(entry.displayPublishedAt)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            NewsStoryActions(websiteURL: entry.originalUrl.flatMap(URL.init(string:)), onReadInApp: onReadInApp)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .contain)
    }
}

private struct WireStoryImage: View {
    let entry: EntryListItem
    let height: CGFloat

    var body: some View {
        let urls = ThumbnailImageURLAttempts.candidates(
            primary: entry.thumbnailUrl,
            fallback: entry.thumbnailFallbackUrl
        )
        NewsStoryImage(urls: urls, height: height)
    }
}

private struct WireSourceLine: View {
    let entry: EntryListItem

    var body: some View {
        Text(entry.wireMetadata?.source.displayName ?? sourceHost ?? "The Social Wire")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var sourceHost: String? {
        entry.wireMetadata?.source.domain
            ?? entry.originalUrl.flatMap(URL.init(string:))?.host
    }
}

private struct WireSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .overlay(alignment: .bottom) { Divider().offset(y: 8) }
    }
}
