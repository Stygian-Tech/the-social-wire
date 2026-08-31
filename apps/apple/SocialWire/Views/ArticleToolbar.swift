import SwiftUI

struct ArticleToolbar: View {
    @Environment(SocialWireAppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    let entry: EntryDetail
    @Binding var showingQuote: Bool
    @Binding var showingReply: Bool
    @State private var reactionFeedback = 0
    @State private var showingTaggedSave = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    reactionFeedback += 1
                    Task {
                        await appModel.saveEntry(
                            entryId: entry.entryId,
                            url: entry.canonicalURL,
                            title: entry.title,
                            linkedWebURL: entry.embedUrl ?? entry.originalUrl
                        )
                    }
                } label: {
                    Label("Save", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)

                Button {
                    showingTaggedSave = true
                } label: {
                    Label(
                        appModel.isSembleReadLaterEnabled ? "Save With Note" : "Save With Tags",
                        systemImage: appModel.isSembleReadLaterEnabled ? "note.text.badge.plus" : "tag"
                    )
                }
                .buttonStyle(.bordered)

                if entry.standardSiteDocumentURI != nil {
                    Button {
                        reactionFeedback += 1
                        Task { await appModel.toggleStandardSiteRecommendation(for: entry) }
                    } label: {
                        Label(
                            appModel.isStandardSiteRecommended(entry)
                                ? "Remove Recommendation"
                                : "Recommend",
                            systemImage: appModel.isStandardSiteRecommended(entry)
                                ? "hand.thumbsup.fill"
                                : "hand.thumbsup"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isArticleSocialStateLoading(for: entry))
                }

                if WireArticleFeedbackContract.normalizeCanonicalURL(
                    entry.wireFeedbackCanonicalUrl ?? ""
                ) != nil {
                    Button {
                        reactionFeedback += 1
                        Task {
                            await appModel.toggleWireArticleFeedback(for: entry, value: .good)
                        }
                    } label: {
                        Label(
                            appModel.wireArticleFeedbackValue(for: entry) == .good
                                ? "Rated Good"
                                : "Good Article",
                            systemImage: appModel.wireArticleFeedbackValue(for: entry) == .good
                                ? "hand.thumbsup.fill"
                                : "hand.thumbsup"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isArticleSocialStateLoading(for: entry))

                    Button {
                        reactionFeedback += 1
                        Task {
                            await appModel.toggleWireArticleFeedback(for: entry, value: .notGood)
                        }
                    } label: {
                        Label(
                            appModel.wireArticleFeedbackValue(for: entry) == .notGood
                                ? "Rated Not Good"
                                : "Not a Good Article",
                            systemImage: appModel.wireArticleFeedbackValue(for: entry) == .notGood
                                ? "hand.thumbsdown.fill"
                                : "hand.thumbsdown"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isArticleSocialStateLoading(for: entry))
                }

                Button {
                    showingQuote = true
                } label: {
                    Label("Quote", systemImage: "quote.bubble")
                }
                .buttonStyle(.bordered)

                if entry.bskyPostUri != nil {
                    Button {
                        showingReply = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                }

                if let url = entry.canonicalURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openURL(url)
                    } label: {
                        Label("Open on Website", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    reactionFeedback += 1
                    Task { await appModel.likeEntry(entry) }
                } label: {
                    Label(
                        appModel.isEntryLiked(entry) ? "Unlike" : "Like",
                        systemImage: appModel.isEntryLiked(entry) ? "heart.fill" : "heart"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(entry.bskyPostUri == nil || appModel.isArticleSocialStateLoading(for: entry))

                Button {
                    reactionFeedback += 1
                    Task { await appModel.repostEntry(entry) }
                } label: {
                    Label(
                        appModel.isEntryReposted(entry) ? "Undo Repost" : "Repost",
                        systemImage: "repeat"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(entry.bskyPostUri == nil || appModel.isArticleSocialStateLoading(for: entry))
            }
        }
        .sheet(isPresented: $showingTaggedSave) {
            if appModel.isSembleReadLaterEnabled {
                SembleNoteEditorSheet { note in
                    reactionFeedback += 1
                    await appModel.saveEntry(
                        entryId: entry.entryId,
                        url: entry.canonicalURL,
                        title: entry.title,
                        linkedWebURL: entry.embedUrl ?? entry.originalUrl,
                        note: note
                    )
                }
            } else {
                SavedTagEditorSheet(
                    title: "Save With Tags",
                    initialTags: [],
                    suggestions: appModel.currentSavedTagCounts.map(\.tag)
                ) { tags in
                    reactionFeedback += 1
                    await appModel.saveEntry(
                        entryId: entry.entryId,
                        url: entry.canonicalURL,
                        title: entry.title,
                        linkedWebURL: entry.embedUrl ?? entry.originalUrl,
                        tags: tags
                    )
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.success, trigger: reactionFeedback)
        .task(id: entry.entryId) {
            await appModel.loadArticleSocialState(for: entry)
        }
    }
}
