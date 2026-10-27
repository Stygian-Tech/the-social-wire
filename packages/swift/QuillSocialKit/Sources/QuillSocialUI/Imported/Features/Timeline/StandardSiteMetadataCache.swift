#if os(iOS)
import Foundation

actor StandardSiteMetadataCache {
    typealias SocialRecords = @Sendable (_ collection: String, _ cursor: String?) async throws -> Data

    private enum Entry {
        case standardSite(StandardSiteMetadataModel.Metadata)
        case ordinaryLink
    }

    private var values: [URL: Entry] = [:]
    private var tasks: [URL: Task<StandardSiteMetadataModel.Resolution, Never>] = [:]
    private let socialRecords: SocialRecords?
    private var socialRecordIndexes: [String: [String: String]] = [:]
    private var socialRecordTasks: [String: Task<[String: String], Never>] = [:]

    init(socialRecords: SocialRecords? = nil) {
        self.socialRecords = socialRecords
    }

    func metadata(for articleURL: URL) async -> StandardSiteMetadataModel.Metadata? {
        if let cached = values[articleURL] {
            switch cached {
            case .standardSite(let metadata): return metadata
            case .ordinaryLink: return nil
            }
        }
        if let task = tasks[articleURL] {
            let resolution = await task.value
            if let cached = values[articleURL], case .standardSite(let metadata) = cached {
                return metadata
            }
            if case .standardSite(let metadata) = resolution {
                let enriched = await enrichViewerState(metadata)
                values[articleURL] = .standardSite(enriched)
                return enriched
            }
            return nil
        }

        let task = Task { await StandardSiteMetadataModel.classify(articleURL: articleURL) }
        tasks[articleURL] = task
        let resolution = await task.value
        tasks[articleURL] = nil
        switch resolution {
        case .standardSite(let metadata):
            let enriched = await enrichViewerState(metadata)
            values[articleURL] = .standardSite(enriched)
            return enriched
        case .ordinaryLink:
            values[articleURL] = .ordinaryLink
        case .unavailable:
            break
        }
        return metadata(from: resolution)
    }

    func updateSubscription(publicationURI: String, recordURI: String?) {
        socialRecordIndexes["site.standard.graph.subscription"]?[publicationURI] = recordURI
        for (url, entry) in values {
            guard case .standardSite(let metadata) = entry,
                  metadata.publicationURI == publicationURI else { continue }
            values[url] = .standardSite(metadata.attachingViewerSubscription(recordURI))
        }
    }

    func updateRecommend(documentURI: String, recordURI: String?) {
        socialRecordIndexes["site.standard.graph.recommend"]?[documentURI] = recordURI
        for (url, entry) in values {
            guard case .standardSite(let metadata) = entry,
                  metadata.documentURI == documentURI else { continue }
            values[url] = .standardSite(metadata.attachingViewerRecommend(recordURI))
        }
    }

    private func enrichViewerState(
        _ metadata: StandardSiteMetadataModel.Metadata
    ) async -> StandardSiteMetadataModel.Metadata {
        async let subscription = recordURI(
            collection: "site.standard.graph.subscription",
            field: "publication",
            target: metadata.publicationURI
        )
        async let recommend = recordURI(
            collection: "site.standard.graph.recommend",
            field: "document",
            target: metadata.documentURI
        )
        return metadata
            .attachingViewerSubscription(await subscription)
            .attachingViewerRecommend(await recommend)
    }

    private func recordURI(collection: String, field: String, target: String) async -> String? {
        guard !target.isEmpty else { return nil }
        if let index = socialRecordIndexes[collection] { return index[target] }
        if let task = socialRecordTasks[collection] { return await task.value[target] }
        guard let socialRecords else { return nil }

        let task = Task<[String: String], Never> {
            var index: [String: String] = [:]
            var cursor: String?
            repeat {
                guard let data = try? await socialRecords(collection, cursor),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    break
                }
                for record in object["records"] as? [[String: Any]] ?? [] {
                    guard let value = record["value"] as? [String: Any],
                          let target = value[field] as? String,
                          let uri = record["uri"] as? String else { continue }
                    index[target] = uri
                }
                cursor = object["cursor"] as? String
            } while cursor != nil
            return index
        }
        socialRecordTasks[collection] = task
        let index = await task.value
        socialRecordTasks[collection] = nil
        socialRecordIndexes[collection] = index
        return index[target]
    }

    private func metadata(
        from resolution: StandardSiteMetadataModel.Resolution
    ) -> StandardSiteMetadataModel.Metadata? {
        if case .standardSite(let metadata) = resolution { return metadata }
        return nil
    }
}

#endif
