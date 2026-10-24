import SwiftUI

struct SocialStandardSiteExternalCard: View {
    let embed: SocialExternalEmbed
    @Environment(SocialWireAppModel.self) private var appModel
    @State private var metadata: StandardSiteSocialEmbed?
    private var state: SocialEmbedViewerState { appModel.socialEmbedViewerState }
    private var subscriptionRecords: [RepoRecord<PublicationSubscriptionRecord>] {
        state.subscriptions.filter { $0.value.publication == metadata?.publicationUri }
    }
    private var recommended: Bool { metadata.map { state.recommendations.contains($0.documentUri) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SocialExternalCard(embed: metadata.map {
                SocialExternalEmbed(uri: $0.articleUrl, title: $0.title,
                    description: $0.description ?? embed.description, thumbnail: embed.thumbnail)
            } ?? embed)
            if let metadata {
                Label(metadata.publicationName, systemImage: "newspaper")
                    .font(.caption.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    actions(metadata)
                    ScrollView(.horizontal) { actions(metadata) }.scrollIndicators(.hidden)
                }
                if let actionError = state.error {
                    Text(actionError).font(.caption).foregroundStyle(.secondary)
                    Button("Retry Actions") { Task { await state.load(model: appModel, force: true) } }
                        .font(.caption).disabled(state.updating)
                }
            }
        }
        .task(id: state.revision) {
            if metadata != nil { await state.load(model: appModel) }
        }
        .task(id: "\(appModel.socialEmbedContextID)|\(embed.uri.absoluteString)") {
            metadata = nil
            let context = appModel.socialEmbedContextID
            guard let viewer = appModel.viewerDID else { return }
            let result = try? await appModel.socialArticleEmbed(url: embed.uri, viewer: viewer)
            guard !Task.isCancelled, appModel.socialEmbedContextID == context else { return }
            metadata = result
            if result != nil { await state.load(model: appModel) }
        }
    }

    private func actions(_ metadata: StandardSiteSocialEmbed) -> some View {
        HStack(spacing: 8) {
            Link("Read Article", destination: metadata.articleUrl)
            Link("View Publication", destination: metadata.publicationUrl)
            Menu {
                Button(subscriptionRecords.isEmpty ? "Subscribe" : "Unsubscribe",
                       systemImage: subscriptionRecords.isEmpty ? "plus.circle" : "minus.circle") {
                    Task { await update(metadata, subscription: true) }
                }
                Button(recommended ? "Unrecommend" : "Recommend",
                       systemImage: recommended ? "hand.thumbsup.fill" : "hand.thumbsup") {
                    Task { await update(metadata, subscription: false) }
                }
                .disabled(metadata.entry.standardSiteDocumentURI == nil)
            } label: { Label("More", systemImage: "ellipsis") }
                .disabled(!state.ready || state.updating || state.context != appModel.socialEmbedContextID)
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func update(_ metadata: StandardSiteSocialEmbed, subscription: Bool) async {
        let context = appModel.socialEmbedContextID
        guard state.ready, !state.updating, state.context == context, let viewer = appModel.viewerDID else { return }
        let wantsSubscription = subscriptionRecords.isEmpty
        let wantsRecommendation = !recommended
        state.updating = true
        defer { if appModel.socialEmbedContextID == context { state.updating = false } }
        do {
            await state.load(model: appModel, force: true)
            guard !Task.isCancelled, state.ready, state.context == context,
                  appModel.socialEmbedContextID == context else { return }
            if subscription {
                if wantsSubscription && subscriptionRecords.isEmpty {
                    try await appModel.pds.createPublicationSubscription(publication: metadata.publicationUri, expectedViewer: viewer)
                } else if !wantsSubscription {
                    for record in subscriptionRecords {
                        guard appModel.socialEmbedContextID == context else { return }
                        guard let rkey = record.uri.split(separator: "/").last else { continue }
                        try await appModel.pds.deletePublicationSubscription(rkey: String(rkey), expectedViewer: viewer)
                    }
                }
            } else if recommended != wantsRecommendation {
                _ = try await appModel.pds.toggleStandardSiteRecommendation(documentURI: metadata.documentUri, expectedViewer: viewer)
            }
            guard !Task.isCancelled, appModel.socialEmbedContextID == context else { return }
            await state.load(model: appModel, force: true)
            if subscription, appModel.socialEmbedContextID == context { await appModel.refreshSidebarProjection() }
            else if appModel.socialEmbedContextID == context { await appModel.loadArticleSocialState(for: metadata.entry) }
        } catch {
            guard !Task.isCancelled, appModel.socialEmbedContextID == context else { return }
            state.failedMutation()
        }
    }
}
