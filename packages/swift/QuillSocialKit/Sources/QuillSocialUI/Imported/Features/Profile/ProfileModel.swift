#if os(iOS)
import Feeds
import Foundation
import Observation

@MainActor
@Observable
final class ProfileModel {
    struct Profile: Decodable, Sendable {
        struct Label: Decodable, Sendable {
            let src: String
            let val: String
            let neg: Bool?
        }

        struct VerificationState: Decodable, Sendable {
            let verifications: [Verification]
        }

        struct Verification: Decodable, Sendable {
            let issuer: String
            let issuerDisplayName: String?
            let issuerHandle: String?
            let uri: String
            let isValid: Bool
        }

        struct Viewer: Decodable, Sendable {
            let following: String?
            let followedBy: String?
        }

        let did: String
        let handle: String
        let displayName: String?
        let description: String?
        let pronouns: String?
        let website: String?
        let avatar: URL?
        let banner: URL?
        let followersCount: Int?
        let followsCount: Int?
        let postsCount: Int?
        let viewer: Viewer?
        let labels: [Label]?
        let verification: VerificationState?

        var websiteURL: URL? {
            guard let website else { return nil }
            let trimmed = website.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let value = trimmed.lowercased().hasPrefix("http://")
                || trimmed.lowercased().hasPrefix("https://")
                ? trimmed
                : "https://\(trimmed)"
            guard let url = URL(string: value),
                  url.scheme == "http" || url.scheme == "https",
                  url.host()?.contains(".") == true else { return nil }
            return url
        }

        var timelineAuthor: TimelineAuthor {
            TimelineAuthor(
                did: did,
                handle: handle,
                displayName: displayName,
                avatarURL: avatar,
                labels: (labels ?? []).map {
                    TimelineLabel(source: $0.src, value: $0.val, isNegation: $0.neg ?? false)
                },
                verifications: (verification?.verifications ?? []).filter(\.isValid).map {
                    TimelineVerification(
                        issuer: $0.issuer,
                        issuerDisplayName: $0.issuerDisplayName,
                        issuerHandle: $0.issuerHandle,
                        uri: $0.uri,
                        isValid: $0.isValid
                    )
                }
            )
        }
    }

    struct Publication: Identifiable, Sendable {
        let id: String
        let name: String
        let description: String?
        let url: URL?
        let logoURL: URL?
    }

    struct NamedResource: Identifiable, Sendable {
        let id: String
        let name: String
        let description: String?
        let avatarURL: URL?
    }

    struct GermAvailability: Sendable {
        let url: URL
        let avatarURL: URL?
    }

    struct ExternalItem: Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let detail: String?
        let imageURL: URL?
    }

    enum ExternalState: Equatable, Sendable {
        case loading, empty, populated, failed
    }

    typealias RepositoryRequest = @Sendable ([String: String]) async throws -> Data
    private(set) var externalStates: [ProfileSection: ExternalState] = [:]
    private var loadingExternalSections: Set<ProfileSection> = []

    private(set) var profile: Profile?
    private(set) var publications: [Publication] = []
    private(set) var lists: [NamedResource] = []
    private(set) var starterPacks: [NamedResource] = []
    private(set) var reviews: [ExternalItem] = []
    private(set) var reading: [ExternalItem] = []
    private(set) var sembleCollections: [ExternalItem] = []
    private(set) var germAvailability: GermAvailability?
    private(set) var isCurrentProfile = false
    private(set) var followingURI: String?
    private(set) var followsViewer = false
    private(set) var isUpdatingFollow = false
    private(set) var followErrorGeneration = 0
    private(set) var timelines: [ProfileSection: TimelineModel] = [:]
    private(set) var isLoading = false
    private(set) var didFail = false
    private var hasLoaded = false

    var links: [URL] {
        guard let profile else { return [] }
        var result = profile.websiteURL.map { [$0] } ?? []
        if let description = profile.description {
            let pattern = #"https?://[^\s<>]+"#
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(description.startIndex..., in: description)
                result += expression.matches(in: description, range: range).compactMap { match in
                    guard let range = Range(match.range, in: description) else { return nil }
                    return URL(string: String(description[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)")))
                }
            }
        }
        var seen = Set<URL>()
        return result.filter { seen.insert($0).inserted }
    }

    func load(actor: String? = nil, services: AppServices) async {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        didFail = false
        defer { isLoading = false }

        do {
            let currentDID = try await services.currentAccountDID()
            let requestedActor = actor ?? currentDID
            let data = try await services.appViewRequest(
                "app.bsky.actor.getProfile",
                ["actor": requestedActor]
            )
            let resolvedProfile = try JSONDecoder().decode(Profile.self, from: data)
            profile = resolvedProfile
            guard let profile else { return }
            isCurrentProfile = profile.did == currentDID
            followingURI = profile.viewer?.following
            followsViewer = profile.viewer?.followedBy != nil
            configureTimelines(actor: profile.did, services: services)
            hasLoaded = true

            // Publish the primary profile immediately. Each optional source publishes
            // independently, so a slow repository cannot hold back another tab.
            isLoading = false
            async let initialTimelineLoad: Void = loadInitialTimeline()
            async let extras: Void = loadOptionalProfileData(did: profile.did, currentDID: currentDID, services: services)
            async let loadedReviews: Void = loadExternalSection(.reviews, did: profile.did)
            async let loadedReading: Void = loadExternalSection(.reading, did: profile.did)
            async let loadedSemble: Void = loadExternalSection(.semble, did: profile.did)
            _ = await (initialTimelineLoad, extras, loadedReviews, loadedReading, loadedSemble)
        } catch is CancellationError {
        } catch {
            didFail = true
        }
    }

    func timeline(for section: ProfileSection) -> TimelineModel? {
        timelines[section]
    }

    var availableSections: [ProfileSection] {
        Self.availableSections(
            hasReviews: !reviews.isEmpty,
            hasReading: !reading.isEmpty,
            hasSembleCollections: !sembleCollections.isEmpty
        )
    }

    nonisolated static func availableSections(
        hasReviews: Bool,
        hasReading: Bool,
        hasSembleCollections: Bool
    ) -> [ProfileSection] {
        ProfileSection.allCases
    }

    func externalState(for section: ProfileSection) -> ExternalState {
        externalStates[section] ?? .loading
    }

    func retryExternalSection(_ section: ProfileSection) async {
        guard let profile else { return }
        await loadExternalSection(section, did: profile.did)
    }

    func loadExternalSection(
        _ section: ProfileSection,
        did: String,
        request: RepositoryRequest = { try await ATProtoPublicRepository.listRecords(parameters: $0) }
    ) async {
        guard !loadingExternalSections.contains(section) else { return }
        let collection: String
        let kind: ExternalItemKind
        switch section {
        case .reviews: collection = "social.popfeed.feed.review"; kind = .review
        case .reading: collection = "buzz.bookhive.book"; kind = .book
        case .semble: collection = "network.cosmik.collection"; kind = .semble
        default: return
        }
        loadingExternalSections.insert(section)
        externalStates[section] = .loading
        defer { loadingExternalSections.remove(section) }
        do {
            let items = try await Self.loadExternalItems(did: did, collection: collection, kind: kind, request: request)
            try Task.checkCancellation()
            switch section {
            case .reviews: reviews = items
            case .reading: reading = items
            case .semble: sembleCollections = items
            default: break
            }
            externalStates[section] = items.isEmpty ? .empty : .populated
        } catch is CancellationError {
        } catch {
            externalStates[section] = .failed
        }
    }

    private func loadOptionalProfileData(did: String, currentDID: String, services: AppServices) async {
        async let publicationLoad: Void = loadPublications(did: did)
        async let germLoad: Void = loadGerm(did: did, currentDID: currentDID, services: services)
        async let listLoad: Void = loadResources(did: did, services: services)
        async let recordLoad: Void = loadProfileRecord(did: did)
        _ = await (publicationLoad, germLoad, listLoad, recordLoad)
    }

    private func loadPublications(did: String) async {
        publications = await Self.loadPublications(did: did)
    }

    private func loadGerm(did: String, currentDID: String, services: AppServices) async {
        germAvailability = await Self.loadGermAvailability(did: did, viewerDID: currentDID, request: services.appViewRequest)
    }

    private func loadResources(did: String, services: AppServices) async {
        async let loadedLists = Self.loadNamedResources(endpoint: "app.bsky.graph.getLists", key: "lists", actor: did, services: services)
        async let loadedStarterPacks = Self.loadNamedResources(endpoint: "app.bsky.graph.getActorStarterPacks", key: "starterPacks", actor: did, services: services)
        lists = await loadedLists
        starterPacks = await loadedStarterPacks
    }

    private func loadProfileRecord(did: String) async {
        guard let data = try? await ATProtoPublicRepository.record(uri: "at://\(did)/app.bsky.actor.profile/self"),
              let record = try? JSONDecoder().decode(ProfileRecordResponse.self, from: data) else { return }
        profile = profile?.merging(record.value)
    }

    var isFollowing: Bool {
        followingURI != nil
    }

    var availableGermDM: GermAvailability? {
        guard Self.shouldShowGermDM(
            isFollowing: isFollowing,
            followsViewer: followsViewer,
            hasDestination: germAvailability != nil
        ) else { return nil }
        return germAvailability
    }

    nonisolated static func shouldShowGermDM(
        isFollowing: Bool,
        followsViewer: Bool,
        hasDestination: Bool
    ) -> Bool {
        isFollowing && followsViewer && hasDestination
    }

    func toggleFollow(services: AppServices) async {
        guard let profile, !isCurrentProfile, !isUpdatingFollow else { return }
        isUpdatingFollow = true
        let previousURI = followingURI
        followingURI = previousURI == nil ? "pending" : nil
        defer { isUpdatingFollow = false }
        do {
            followingURI = try await services.updateFollow(profile.did, previousURI)
        } catch is CancellationError {
            followingURI = previousURI
        } catch {
            followingURI = previousURI
            followErrorGeneration += 1
        }
    }

    private func configureTimelines(actor: String, services: AppServices) {
        for section in [ProfileSection.posts, .replies, .media, .likes] {
            let source = ATProtoTimelineSource { parameters in
                var requestParameters = parameters
                requestParameters["actor"] = actor
                let endpoint: String
                switch section {
                case .posts:
                    endpoint = "app.bsky.feed.getAuthorFeed"
                    requestParameters["filter"] = "posts_no_replies"
                case .replies:
                    endpoint = "app.bsky.feed.getAuthorFeed"
                    requestParameters["filter"] = "posts_with_replies"
                case .media:
                    endpoint = "app.bsky.feed.getAuthorFeed"
                    requestParameters["filter"] = "posts_with_media"
                case .likes:
                    endpoint = "app.bsky.feed.getActorLikes"
                default:
                    preconditionFailure("Unsupported timeline section")
                }
                return try await services.appViewRequest(endpoint, requestParameters)
            }
            timelines[section] = TimelineModel(source: source)
        }
    }

    private func loadInitialTimeline() async {
        await timelines[.posts]?.load()
    }

    private enum ExternalItemKind: Sendable {
        case review
        case book
        case semble
    }

    private nonisolated static func loadExternalItems(
        did: String,
        collection: String,
        kind: ExternalItemKind,
        request: RepositoryRequest
    ) async throws -> [ExternalItem] {
        let data = try await request([
            "repo": did,
            "collection": collection,
            "limit": "100",
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["records"] as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }

        return records.compactMap { record in
            guard let uri = record["uri"] as? String,
                  let value = record["value"] as? [String: Any] else { return nil }
            switch kind {
            case .review:
                guard let title = value["title"] as? String else { return nil }
                let rating = value["rating"] as? Int
                let workType = (value["creativeWorkType"] as? String)?
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                return ExternalItem(
                    id: uri,
                    title: title,
                    subtitle: rating.map { "\($0)/10" },
                    detail: value["text"] as? String ?? workType,
                    imageURL: (value["posterUrl"] as? String).flatMap(URL.init(string:))
                )
            case .book:
                guard let title = value["title"] as? String else { return nil }
                let status = (value["status"] as? String)?.split(separator: "#").last
                    .map(String.init)
                return ExternalItem(
                    id: uri,
                    title: title,
                    subtitle: value["authors"] as? String,
                    detail: value["review"] as? String ?? status,
                    imageURL: nil
                )
            case .semble:
                guard let name = value["name"] as? String else { return nil }
                return ExternalItem(
                    id: uri,
                    title: name,
                    subtitle: value["accessType"] as? String,
                    detail: value["description"] as? String,
                    imageURL: nil
                )
            }
        }
    }

    private nonisolated static func loadPublications(did: String) async -> [Publication] {
        guard let data = try? await ATProtoPublicRepository.listRecords(parameters: [
            "repo": did,
            "collection": "site.standard.publication",
            "limit": "100",
        ]), let response = try? JSONDecoder().decode(PublicationResponse.self, from: data) else {
            return []
        }

        return await withTaskGroup(of: Publication?.self) { group in
            for record in response.records {
                group.addTask {
                    let logoURL: URL? = if let cid = record.value.icon?.reference.link {
                        try? await ATProtoPublicRepository.blobURL(did: did, cid: cid)
                    } else { nil }
                    return Publication(
                        id: record.uri,
                        name: record.value.name,
                        description: record.value.description,
                        url: record.value.url,
                        logoURL: logoURL
                    )
                }
            }
            var publications: [Publication] = []
            for await publication in group {
                if let publication { publications.append(publication) }
            }
            return publications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private nonisolated static func loadGermAvailability(
        did: String,
        viewerDID: String,
        request: @escaping AppServices.AppViewRequest
    ) async -> GermAvailability? {
        guard did != viewerDID else { return nil }
        guard let data = try? await ATProtoPublicRepository.record(
            uri: "at://\(did)/com.germnetwork.declaration/self"
        ), let response = try? JSONDecoder().decode(GermResponse.self, from: data),
              let messageMe = response.value.messageMe,
              messageMe.showButtonTo != "none" else { return nil }

        var components = URLComponents(
            url: messageMe.messageMeURL.appending(path: "iOS"),
            resolvingAgainstBaseURL: false
        )
        components?.fragment = "\(did)+\(viewerDID)"
        guard let url = components?.url else { return nil }

        let avatarURL: URL?
        if let profileData = try? await request(
            "app.bsky.actor.getProfile",
            ["actor": "germnetwork.com"]
        ) {
            avatarURL = try? JSONDecoder().decode(GermProfile.self, from: profileData).avatar
        } else {
            avatarURL = nil
        }
        return GermAvailability(url: url, avatarURL: avatarURL)
    }

    private nonisolated static func loadNamedResources(
        endpoint: String,
        key: String,
        actor: String,
        services: AppServices
    ) async -> [NamedResource] {
        guard let data = try? await services.appViewRequest(endpoint, ["actor": actor, "limit": "100"]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object[key] as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let uri = value["uri"] as? String else { return nil }
            let record = value["record"] as? [String: Any]
            let creator = value["creator"] as? [String: Any]
            let name = value["name"] as? String ?? record?["name"] as? String ?? "Untitled"
            return NamedResource(
                id: uri,
                name: name,
                description: value["description"] as? String ?? record?["description"] as? String,
                avatarURL: ((value["avatar"] as? String) ?? (creator?["avatar"] as? String))
                    .flatMap(URL.init(string:))
            )
        }
    }
}

private extension ProfileModel.Profile {
    func merging(_ record: ProfileModel.ProfileRecord) -> Self {
        Self(
            did: did,
            handle: handle,
            displayName: displayName,
            description: description,
            pronouns: record.pronouns ?? pronouns,
            website: record.website ?? website,
            avatar: avatar,
            banner: banner,
            followersCount: followersCount,
            followsCount: followsCount,
            postsCount: postsCount,
            viewer: viewer,
            labels: labels,
            verification: verification
        )
    }
}

private extension ProfileModel {
    struct ProfileRecordResponse: Decodable {
        let value: ProfileRecord
    }

    struct ProfileRecord: Decodable {
        let pronouns: String?
        let website: String?
    }

    struct PublicationResponse: Decodable {
        let records: [PublicationRecord]
    }

    struct PublicationRecord: Decodable {
        let uri: String
        let value: PublicationValue
    }

    struct PublicationValue: Decodable {
        let name: String
        let description: String?
        let url: URL?
        let icon: Blob?
    }

    struct Blob: Decodable {
        let reference: Link

        private enum CodingKeys: String, CodingKey {
            case reference = "ref"
        }
    }

    struct Link: Decodable {
        let link: String

        private enum CodingKeys: String, CodingKey {
            case link = "$link"
        }
    }

    struct GermResponse: Decodable {
        let value: GermValue
    }

    struct GermValue: Decodable {
        let messageMe: GermMessageMe?
    }

    struct GermMessageMe: Decodable {
        let showButtonTo: String
        let messageMeURL: URL

        private enum CodingKeys: String, CodingKey {
            case showButtonTo, messageMeURL = "messageMeUrl"
        }
    }

    struct GermProfile: Decodable {
        let avatar: URL?
    }
}

#endif
