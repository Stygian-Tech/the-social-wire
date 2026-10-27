#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class AccountBadgeProfileStore {
    typealias Loader = @Sendable (_ did: String) async throws -> Data

    private let profileLoader: Loader
    private let labelerLoader: Loader
    @ObservationIgnored private(set) var profiles: [String: AccountBadgeProfile] = [:]
    @ObservationIgnored private(set) var labelDisplayNames: [String: [String: String]] = [:]
    private var loadingDIDs: Set<String> = []
    private var loadedDIDs: Set<String> = []

    init(profileLoader: @escaping Loader, labelerLoader: @escaping Loader) {
        self.profileLoader = profileLoader
        self.labelerLoader = labelerLoader
    }

    func profile(for did: String) -> AccountBadgeProfile? {
        profiles[did]
    }

    func displayName(for label: String, from did: String) -> String {
        labelDisplayNames[did]?[label]
            ?? label.replacingOccurrences(of: "-", with: " ").capitalized
    }

    func load(did: String) async {
        guard !loadedDIDs.contains(did), loadingDIDs.insert(did).inserted else { return }
        defer { loadingDIDs.remove(did) }

        async let profileData = try? profileLoader(did)
        async let labelerData = try? labelerLoader(did)

        let loadedProfileData = await profileData
        let loadedLabelerData = await labelerData
        let profile: AccountBadgeProfile? = if let loadedProfileData {
            await Task.detached {
                try? JSONDecoder().decode(AccountBadgeProfile.self, from: loadedProfileData)
            }.value
        } else { nil }
        let labeler: AccountLabelerServiceResponse? = if let loadedLabelerData {
            await Task.detached {
                try? JSONDecoder().decode(AccountLabelerServiceResponse.self, from: loadedLabelerData)
            }.value
        } else { nil }

        if let profile {
            profiles[did] = profile
        }
        if let response = labeler {
            let languageCode = Locale.current.language.languageCode?.identifier
            labelDisplayNames[did] = response.displayNames(preferredLanguageCode: languageCode)
        }
        loadedDIDs.insert(did)
    }
}

#endif
