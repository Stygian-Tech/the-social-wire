import Foundation
import Testing
@testable import SocialWire

@Suite("Social Standard.site rich embed")
struct StandardSiteSocialEmbedTests {
    private func decode(articleURL: String = "https://babesky.leaflet.pub/3mdvrts2y7s25", publicationURI: String = "at://did:plc:author/site.standard.publication/pub") throws -> StandardSiteSocialEmbed {
        let data = try JSONSerialization.data(withJSONObject: [
            "documentUri": "at://did:plc:author/site.standard.document/doc",
            "publicationUri": publicationURI,
            "publicationName": "Babesky Blog",
            "publicationUrl": "https://babesky.leaflet.pub",
            "articleUrl": articleURL,
            "title": "Lifestyles of the Burntout and Struggling",
            "authorDid": "did:plc:author",
        ])
        return try JSONDecoder().decode(StandardSiteSocialEmbed.self, from: data)
    }

    @Test func decodesGatewayContractAndUsesSeparateActionTargets() throws {
        let embed = try decode()
        #expect(embed.isValid)
        #expect(embed.entry.standardSiteDocumentURI == embed.documentUri)
        #expect(embed.publication.publicationId == embed.publicationUri)
        #expect(embed.publication.subscriptionPublicationId == embed.publicationUri)
        #expect(embed.entry.canonicalURL == embed.articleUrl)
        #expect(embed.publication.publicationSiteUrls == [embed.publicationUrl.absoluteString])
        #expect(embed.description == nil)
    }

    @Test(arguments: ["javascript:alert(1)", "http://example.com/article", "https://user@example.com/article"])
    func rejectsUnsafeArticleDestinations(url: String) throws {
        #expect(try !decode(articleURL: url).isValid)
    }

    @Test(arguments: ["at://did:plc:author/site.standard.document/pub", "at://did:plc:author/site.standard.publication", "https://example.com"])
    func rejectsNonPublicationActionTargets(uri: String) throws {
        #expect(try !decode(publicationURI: uri).isValid)
    }
}

@Suite("Social embed viewer snapshot lifecycle")
@MainActor
struct SocialEmbedViewerStateTests {
    @Test func concurrentCardsShareOneFetch() async {
        let state = SocialEmbedViewerState()
        let epoch = UUID()
        var continuation: CheckedContinuation<SocialEmbedViewerState.Snapshot, Never>?
        var calls = 0
        let fetch: @MainActor () async throws -> SocialEmbedViewerState.Snapshot = {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { await state.load(context: epoch, isCurrent: { true }, fetch: fetch) }
        while continuation == nil { await Task.yield() }
        let second = Task { await state.load(context: epoch, isCurrent: { true }, fetch: fetch) }
        await Task.yield()
        continuation?.resume(returning: .init(subscriptions: [], recommendations: ["document"]))
        await first.value
        await second.value
        #expect(calls == 1)
        #expect(state.ready)
        #expect(state.recommendations == ["document"])
    }

    @Test func lateOldEpochCannotOverwriteNewAccount() async {
        let state = SocialEmbedViewerState()
        let old = UUID()
        let new = UUID()
        var active = old
        var continuation: CheckedContinuation<SocialEmbedViewerState.Snapshot, Never>?
        let oldLoad = Task {
            await state.load(context: old, isCurrent: { active == old }) {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        active = new
        await state.load(context: new, isCurrent: { active == new }) {
            .init(subscriptions: [], recommendations: ["new"])
        }
        continuation?.resume(returning: .init(subscriptions: [], recommendations: ["old"]))
        await oldLoad.value
        #expect(state.context == new)
        #expect(state.ready)
        #expect(state.recommendations == ["new"])
    }

    @Test func invalidatedLateLoadCannotOverwriteSameEpochReplacement() async {
        let state = SocialEmbedViewerState()
        let epoch = UUID()
        var continuation: CheckedContinuation<SocialEmbedViewerState.Snapshot, Never>?
        let first = Task {
            await state.load(context: epoch, isCurrent: { true }) {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        state.invalidate()
        await state.load(context: epoch, isCurrent: { true }) {
            .init(subscriptions: [], recommendations: ["replacement"])
        }
        continuation?.resume(returning: .init(subscriptions: [], recommendations: ["obsolete"]))
        await first.value
        #expect(state.ready)
        #expect(state.recommendations == ["replacement"])
        await state.load(context: epoch, force: true, isCurrent: { true }) {
            .init(subscriptions: [], recommendations: ["refreshed"])
        }
        #expect(state.recommendations == ["refreshed"])
    }
}
