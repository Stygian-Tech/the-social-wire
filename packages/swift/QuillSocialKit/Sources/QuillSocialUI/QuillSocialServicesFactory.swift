#if os(iOS)
import ATProtoCore
import Feeds
import Foundation

@MainActor
enum QuillSocialServicesFactory {
    static func make(configuration: QuillSocialConfiguration) -> AppServices {
        // Preferences must not recursively request their own accepted-labeler list.
        let preferencesRequest: @Sendable () async throws -> Data = {
            if let request = configuration.appViewRequestWithContext {
                return try await request("app.bsky.actor.getPreferences", [:], ContentProviderPreferences.activeProxy, [])
            }
            return try await configuration.appViewRequest("app.bsky.actor.getPreferences", [:])
        }
        let subscribedLabelers = SubscribedLabelersStore(
            includesBluesky: ContentProviderPreferences.includesBlueskyModeration,
            additionalDIDs: ContentProviderPreferences.additionalLabelerDIDs,
            request: preferencesRequest
        )
        let appViewRequest: QuillSocialConfiguration.Request = { nsid, parameters in
            if let request = configuration.appViewRequestWithContext {
                let labelers = try await subscribedLabelers.dids()
                return try await request(nsid, parameters, ContentProviderPreferences.activeProxy, labelers)
            }
            return try await configuration.appViewRequest(nsid, parameters)
        }
        let appViewProcedure: QuillSocialConfiguration.Procedure = { nsid, body in
            let result: Data
            if let procedure = configuration.appViewProcedureWithContext {
                result = try await procedure(nsid, body, ContentProviderPreferences.activeProxy)
            } else {
                result = try await configuration.appViewProcedure(nsid, body)
            }
            if nsid == "app.bsky.actor.putPreferences" {
                await subscribedLabelers.updateConfiguration(
                    includesBluesky: ContentProviderPreferences.includesBlueskyModeration,
                    additionalDIDs: ContentProviderPreferences.additionalLabelerDIDs
                )
            }
            return result
        }
        let standardSiteCache = StandardSiteMetadataCache { collection, cursor in
            var parameters = ["repo": configuration.viewerDID, "collection": collection, "limit": "100"]
            if let cursor { parameters["cursor"] = cursor }
            return try await configuration.pdsRequest("com.atproto.repo.listRecords", parameters)
        }
        let tangledStringCache = TangledStringMetadataCache()
        let atmoRsvpCache = AtmoRsvpMetadataCache(
            sessionDID: { configuration.viewerDID },
            follows: { actor, cursor in
                var parameters = ["actor": actor, "limit": "100"]
                if let cursor { parameters["cursor"] = cursor }
                return try await appViewRequest("app.bsky.graph.getFollows", parameters)
            }
        )
        return AppServices(
            timelineSource: StandardSiteEnrichedTimelineSource(
                base: ATProtoTimelineSource { parameters in
                    try await appViewRequest("app.bsky.feed.getTimeline", parameters)
                },
                resolver: { await standardSiteCache.metadata(for: $0) },
                tangledResolver: { await tangledStringCache.metadata(for: $0) },
                atmoResolver: { await atmoRsvpCache.metadata(for: $0) }
            ),
            appViewRequest: { nsid, parameters in
                try await appViewRequest(nsid, parameters)
            },
            appViewProcedure: { nsid, body in
                try await appViewProcedure(nsid, body)
            },
            chatRequest: { nsid, parameters in
                try await configuration.chatRequest(nsid, parameters)
            },
            chatProcedure: { nsid, body in
                try await configuration.chatProcedure(nsid, body)
            },
            currentAccountDID: {
                configuration.viewerDID
            },
            activeLabelerDIDs: {
                try await subscribedLabelers.dids()
            },
            updateLabelerConfiguration: { includesBluesky, additionalDIDs in
                await subscribedLabelers.updateConfiguration(
                    includesBluesky: includesBluesky,
                    additionalDIDs: additionalDIDs
                )
            },
            preferencesRequest: preferencesRequest,
            preferencesUpdate: { body in
                _ = try await appViewProcedure("app.bsky.actor.putPreferences", body)
            },
            feedTimelineSource: { feed in
                StandardSiteEnrichedTimelineSource(
                    base: ATProtoTimelineSource(feedURI: feed.uri.description) { parameters in
                        try await appViewRequest("app.bsky.feed.getFeed", parameters)
                    },
                    resolver: { await standardSiteCache.metadata(for: $0) },
                    tangledResolver: { await tangledStringCache.metadata(for: $0) },
                    atmoResolver: { await atmoRsvpCache.metadata(for: $0) }
                )
            },
            pinnedFeedsSource: ATProtoPinnedFeedsSource(
                preferencesRequest: preferencesRequest,
                preferencesUpdate: { body in
                    _ = try await appViewProcedure("app.bsky.actor.putPreferences", body)
                },
                feedRequest: { uri in
                    try await appViewRequest("app.bsky.feed.getFeedGenerator", ["feed": uri])
                },
                generatorRecordRequest: { value in
                    let uri = try ATURI(value)
                    guard let collection = uri.collection, let recordKey = uri.recordKey else {
                        throw URLError(.badURL)
                    }
                    return try await configuration.publicPDSRequest(
                        uri.authority.description,
                        "com.atproto.repo.getRecord",
                        ["repo": uri.authority.description, "collection": collection.description,
                         "rkey": recordKey.description]
                    )
                }
            ),
            postThreadSource: StandardSiteEnrichedPostThreadSource(
                base: ATProtoPostThreadSource { parameters in
                    try await appViewRequest("app.bsky.feed.getPostThread", parameters)
                },
                resolver: { await standardSiteCache.metadata(for: $0) },
                tangledResolver: { await tangledStringCache.metadata(for: $0) },
                atmoResolver: { await atmoRsvpCache.metadata(for: $0) }
            ),
            postActionSource: ATProtoPostActionSource(
                sessionDID: {
                    configuration.viewerDID
                },
                procedure: { nsid, body in
                    try await configuration.pdsProcedure(nsid, body)
                },
                blobUpload: { data, mimeType in
                    try await configuration.uploadBlob(data, mimeType)
                }
            ),
            storySource: ATProtoStorySource(
                sessionDID: {
                    configuration.viewerDID
                },
                profileRequest: { parameters in
                    try await appViewRequest("app.bsky.actor.getProfile", parameters)
                },
                followsRequest: { parameters in
                    try await appViewRequest("app.bsky.graph.getFollows", parameters)
                },
                recordsRequest: { parameters in
                    guard let repo = parameters["repo"] else { throw URLError(.badURL) }
                    return try await configuration.publicPDSRequest(repo, "com.atproto.repo.listRecords", parameters)
                },
                procedure: { nsid, body in
                    try await configuration.pdsProcedure(nsid, body)
                },
                blobUpload: { data, mimeType in
                    try await configuration.uploadBlob(data, mimeType)
                }
            ),
            currentProfile: CurrentProfileModel {
                let did = configuration.viewerDID
                let data = try await appViewRequest("app.bsky.actor.getProfile", ["actor": did])
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let value = object?["avatar"] as? String, let url = URL(string: value) else {
                    return nil
                }
                let (avatarData, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    return nil
                }
                return avatarData
            },
            accountBadgeProfiles: AccountBadgeProfileStore(
                profileLoader: { did in
                    try await appViewRequest("app.bsky.actor.getProfile", ["actor": did])
                },
                labelerLoader: { did in
                    try await appViewRequest("app.bsky.labeler.getServices", ["dids": did, "detailed": "true"])
                }
            ),
            updateFollow: { actorDID, existingRecordURI in
                let viewerDID = configuration.viewerDID
                if let existingRecordURI,
                   let rkey = existingRecordURI.split(separator: "/").last.map(String.init) {
                    let body = try JSONSerialization.data(withJSONObject: [
                        "repo": viewerDID,
                        "collection": "app.bsky.graph.follow",
                        "rkey": rkey,
                    ])
                    _ = try await configuration.pdsProcedure("com.atproto.repo.deleteRecord", body)
                    return nil
                }
                let body = try JSONSerialization.data(withJSONObject: [
                    "repo": viewerDID,
                    "collection": "app.bsky.graph.follow",
                    "record": [
                        "$type": "app.bsky.graph.follow",
                        "subject": actorDID,
                        "createdAt": ISO8601DateFormatter().string(from: Date()),
                    ],
                ])
                let response = try await configuration.pdsProcedure("com.atproto.repo.createRecord", body)
                let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
                return object?["uri"] as? String
            },
            resolveLinkPreview: { url in
                guard let preview = await ComposerLinkPreviewResolver.resolve(url) else { return nil }
                async let standardSite = standardSiteCache.metadata(for: url)
                async let tangledString = tangledStringCache.metadata(for: url)
                async let atmoRsvp = atmoRsvpCache.metadata(for: url)
                let enriched = preview.embed
                    .attachingStandardSite(await standardSite)
                    .attachingTangledString(await tangledString)
                    .attachingAtmoRsvp(await atmoRsvp)
                return ComposerLinkPreview(embed: enriched, attachment: preview.attachment)
            },
            updatePublicationSubscription: { publicationURI, existingRecordURI in
                let viewerDID = configuration.viewerDID
                if let existingRecordURI,
                   let rkey = existingRecordURI.split(separator: "/").last.map(String.init) {
                    let body = try JSONSerialization.data(withJSONObject: [
                        "repo": viewerDID,
                        "collection": "site.standard.graph.subscription",
                        "rkey": rkey,
                    ])
                    _ = try await configuration.pdsProcedure("com.atproto.repo.deleteRecord", body)
                    await standardSiteCache.updateSubscription(publicationURI: publicationURI, recordURI: nil)
                    return nil
                }
                let body = try JSONSerialization.data(withJSONObject: [
                    "repo": viewerDID,
                    "collection": "site.standard.graph.subscription",
                    "record": [
                        "$type": "site.standard.graph.subscription",
                        "publication": publicationURI,
                        "createdAt": ISO8601DateFormatter().string(from: Date()),
                    ],
                ])
                let response = try await configuration.pdsProcedure("com.atproto.repo.createRecord", body)
                let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
                let uri = object?["uri"] as? String
                await standardSiteCache.updateSubscription(publicationURI: publicationURI, recordURI: uri)
                return uri
            },
            updateDocumentRecommend: { documentURI, existingRecordURI in
                let viewerDID = configuration.viewerDID
                if let existingRecordURI,
                   let rkey = existingRecordURI.split(separator: "/").last.map(String.init) {
                    let body = try JSONSerialization.data(withJSONObject: [
                        "repo": viewerDID,
                        "collection": "site.standard.graph.recommend",
                        "rkey": rkey,
                    ])
                    _ = try await configuration.pdsProcedure("com.atproto.repo.deleteRecord", body)
                    await standardSiteCache.updateRecommend(documentURI: documentURI, recordURI: nil)
                    return nil
                }
                let body = try JSONSerialization.data(withJSONObject: [
                    "repo": viewerDID,
                    "collection": "site.standard.graph.recommend",
                    "record": [
                        "$type": "site.standard.graph.recommend",
                        "document": documentURI,
                        "createdAt": ISO8601DateFormatter().string(from: Date()),
                    ],
                ])
                let response = try await configuration.pdsProcedure("com.atproto.repo.createRecord", body)
                let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
                let uri = object?["uri"] as? String
                await standardSiteCache.updateRecommend(documentURI: documentURI, recordURI: uri)
                return uri
            },
            updateEventRsvp: { eventURI, eventCID, status, existingRkey in
                let viewerDID = configuration.viewerDID
                if status == nil, let existingRkey {
                    let recordURI = "at://\(viewerDID)/community.lexicon.calendar.rsvp/\(existingRkey)"
                    let body = try JSONSerialization.data(withJSONObject: [
                        "repo": viewerDID,
                        "collection": "community.lexicon.calendar.rsvp",
                        "rkey": existingRkey,
                    ])
                    _ = try await configuration.pdsProcedure("com.atproto.repo.deleteRecord", body)
                    await atmoRsvpCache.notifyUpdate(uri: recordURI)
                    await atmoRsvpCache.update(eventURI: eventURI, status: nil, rkey: nil)
                    return nil
                }
                guard let status else { return nil }
                let record: [String: Any] = [
                    "$type": "community.lexicon.calendar.rsvp",
                    "status": "community.lexicon.calendar.rsvp#\(status.rawValue)",
                    "subject": ["uri": eventURI, "cid": eventCID],
                    "createdAt": ISO8601DateFormatter().string(from: Date()),
                ]
                var payload: [String: Any] = [
                    "repo": viewerDID,
                    "collection": "community.lexicon.calendar.rsvp",
                    "record": record,
                ]
                let method: String
                if let existingRkey {
                    payload["rkey"] = existingRkey
                    method = "com.atproto.repo.putRecord"
                } else {
                    method = "com.atproto.repo.createRecord"
                }
                let body = try JSONSerialization.data(withJSONObject: payload)
                let response = try await configuration.pdsProcedure(method, body)
                let updatedRkey: String?
                if let existingRkey {
                    updatedRkey = existingRkey
                } else {
                    let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
                    updatedRkey = (object?["uri"] as? String)?.split(separator: "/").last.map(String.init)
                }
                if let updatedRkey {
                    let recordURI = "at://\(viewerDID)/community.lexicon.calendar.rsvp/\(updatedRkey)"
                    await atmoRsvpCache.notifyUpdate(uri: recordURI)
                }
                await atmoRsvpCache.update(eventURI: eventURI, status: status, rkey: updatedRkey)
                return updatedRkey
            }
        )
    }
}
#endif
