#if os(iOS)
import Feeds
import SwiftUI

struct ExternalEmbedView: View {
    let embed: TimelineExternalEmbed

    @Environment(AppServices.self) private var services
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var subscriptionURI: String?
    @State private var recommendURI: String?
    @State private var isUpdatingSubscription = false
    @State private var isUpdatingRecommend = false
    @State private var actionFeedback = 0
    @State private var showsGIFViewer = false
    @State private var loadedGIFAspectRatio: CGFloat?

    init(embed: TimelineExternalEmbed) {
        self.embed = embed
        _subscriptionURI = State(initialValue: embed.standardSite?.viewerSubscriptionURI)
        _recommendURI = State(initialValue: embed.standardSite?.viewerRecommendURI)
    }

    var body: some View {
        Group {
            if let gifMediaURL {
                Button {
                    showsGIFViewer = true
                } label: {
                    FeedMediaViewport(aspectRatio: loadedGIFAspectRatio ?? CGFloat(embed.gifAspectRatio ?? 1.2)) {
                        AnimatedImageView(url: gifMediaURL, contentMode: .fit) { ratio in
                            loadedGIFAspectRatio = ratio
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !gifAltText.isEmpty {
                            AltTextBadge(hasAltText: true)
                                .padding(8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(embed.title.isEmpty ? "Animated GIF" : embed.title)
                .accessibilityHint("Opens the full-screen image viewer")
            } else if let atmoRsvp = embed.atmoRsvp {
                AtmoRsvpEmbedView(
                    metadata: atmoRsvp,
                    destination: embed.uri,
                    thumbnailURL: embed.thumbnailURL
                )
            } else if let tangledString = embed.tangledString {
                TangledStringEmbedView(metadata: tangledString, destination: embed.uri)
            } else {
                standardEmbed
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: embed.uri) { loadedGIFAspectRatio = nil }
        .accessibilityHint(
            gifMediaURL == nil ? "Opens the linked article" : "Opens the full-screen image viewer"
        )
        .fullScreenCover(isPresented: $showsGIFViewer) {
            if let gifMediaURL {
                FullScreenImageViewer(
                    images: [TimelineImage(
                        thumbnailURL: gifMediaURL,
                        fullsizeURL: gifMediaURL,
                        altText: embed.description.isEmpty ? embed.title : embed.description
                    )],
                    selectedImageID: gifMediaURL
                )
            }
        }
    }

    private var standardEmbed: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Link(destination: embed.uri) {
                VStack(alignment: .leading, spacing: 10) {
                    if let thumbnailURL = embed.thumbnailURL {
                        FeedMediaViewport(aspectRatio: 1.91, cornerRadius: 8) {
                            AsyncImage(url: thumbnailURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(.fill.tertiary)
                            }
                        }
                    }

                    if let siteName = embed.displaySiteName {
                        Text(siteName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(embed.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)

                if let metadata = embed.standardSite {
                    HStack(spacing: 8) {
                    AsyncImage(url: metadata.logoURL) { image in image.resizable().scaledToFill() }
                        placeholder: { Image(systemName: "newspaper.fill") }
                        .frame(width: 28, height: 28)
                        .clipShape(.rect(cornerRadius: 6))
                    Text(metadata.publicationName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        AsyncImage(url: metadata.authorAvatarURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.gray)
                        }
                        .frame(width: 18, height: 18)
                        .clipShape(.circle)

                        Text("by \(metadata.authorName ?? "Author")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    }
                    .frame(height: 28)
                }
            }
            .padding(10)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5)
            }
            .clipShape(.rect(cornerRadius: 12))

            if let metadata = embed.standardSite {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView(.horizontal) {
                        standardSiteActionRow(metadata)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    standardSiteActionRow(metadata)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sensoryFeedback(.selection, trigger: actionFeedback)
    }

    private var gifMediaURL: URL? {
        embed.animatedGIFURL
    }

    private var gifAltText: String {
        embed.description.isEmpty ? embed.title : embed.description
    }

    private func standardSiteActionRow(_ metadata: StandardSiteEmbedMetadata) -> some View {
        HStack(spacing: 6) {
            Link(destination: embed.uri) {
                HStack(spacing: 4) {
                    Text("Read Article")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                    Image(systemName: "arrow.up.forward.app")
                }
            }

            Link(destination: metadata.publicationURL) {
                HStack(spacing: 4) {
                    Text("View Publication")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                    Image(systemName: "arrow.up.forward.app")
                }
            }

            Menu {
                Button {
                    updateSubscription(metadata)
                } label: {
                    Label(
                        subscriptionURI == nil ? "Subscribe" : "Unsubscribe",
                        systemImage: subscriptionURI == nil ? "plus.circle" : "minus.circle"
                    )
                }
                .disabled(isUpdatingSubscription)

                Button {
                    updateRecommend(metadata)
                } label: {
                    Label(
                        recommendURI == nil ? "Recommend" : "Unrecommend",
                        systemImage: recommendURI == nil ? "hand.thumbsup" : "hand.thumbsup.fill"
                    )
                }
                .disabled(isUpdatingRecommend || metadata.documentURI.isEmpty)
            } label: {
                HStack(spacing: 4) {
                    Text("More")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                    Image(systemName: "ellipsis")
                }
            }
        }
        .buttonStyle(ThemeChipButtonStyle())
        .frame(height: 34)
    }

    private func updateSubscription(_ metadata: StandardSiteEmbedMetadata) {
        guard !isUpdatingSubscription else { return }
        isUpdatingSubscription = true
        Task {
            defer { isUpdatingSubscription = false }
            do {
                subscriptionURI = try await services.updatePublicationSubscription(
                    metadata.publicationURI,
                    subscriptionURI
                )
                actionFeedback += 1
            } catch {
                return
            }
        }
    }

    private func updateRecommend(_ metadata: StandardSiteEmbedMetadata) {
        guard !isUpdatingRecommend, !metadata.documentURI.isEmpty else { return }
        isUpdatingRecommend = true
        Task {
            defer { isUpdatingRecommend = false }
            do {
                recommendURI = try await services.updateDocumentRecommend(
                    metadata.documentURI,
                    recommendURI
                )
                actionFeedback += 1
            } catch {
                return
            }
        }
    }
}

#endif
