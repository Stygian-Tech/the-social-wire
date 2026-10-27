#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class LabelerModerationModel {
    struct LabelOption: Identifiable, Hashable {
        let id: String
        let name: String
        let description: String?
        let defaultVisibility: String
    }

    var profile: ActorTypeaheadResult?
    var labels: [LabelOption] = []
    var visibility: [String: String] = [:]
    var isLoading = true
    var errorMessage: String?

    private var preferences: [[String: Any]] = []

    func load(did: String, services: AppServices) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let profileData = services.appViewRequest(
                "app.bsky.actor.getProfile",
                ["actor": did]
            )
            async let labelerData = services.appViewRequest(
                "app.bsky.labeler.getServices",
                ["dids": did, "detailed": "true"]
            )
            async let preferencesData = services.preferencesRequest()

            let (loadedProfile, loadedLabeler, loadedPreferences) = try await (
                profileData,
                labelerData,
                preferencesData
            )
            profile = try JSONDecoder().decode(ActorTypeaheadResult.self, from: loadedProfile)
            try parseLabeler(data: loadedLabeler)
            try parsePreferences(data: loadedPreferences, labelerDID: did)
        } catch {
            errorMessage = "The Social Wire couldn’t load this labeler’s moderation settings."
        }
    }

    func save(did: String, services: AppServices) async throws {
        let labelIDs = Set(labels.map(\.id))
        preferences.removeAll { preference in
            preference["$type"] as? String == "app.bsky.actor.defs#contentLabelPref"
                && preference["labelerDid"] as? String == did
                && labelIDs.contains(preference["label"] as? String ?? "")
        }
        for label in labels {
            preferences.append([
                "$type": "app.bsky.actor.defs#contentLabelPref",
                "labelerDid": did,
                "label": label.id,
                "visibility": visibility[label.id] ?? label.defaultVisibility,
            ])
        }
        let body = try JSONSerialization.data(withJSONObject: ["preferences": preferences])
        try await services.preferencesUpdate(body)
    }

    private func parseLabeler(data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let view = (root?["views"] as? [[String: Any]])?.first
        let policies = view?["policies"] as? [String: Any]
        let definitions = policies?["labelValueDefinitions"] as? [[String: Any]] ?? []
        labels = definitions.compactMap { definition in
            guard let identifier = definition["identifier"] as? String else { return nil }
            let locale = (definition["locales"] as? [[String: Any]])?.first
            return LabelOption(
                id: identifier,
                name: locale?["name"] as? String ?? identifier,
                description: locale?["description"] as? String,
                defaultVisibility: definition["defaultSetting"] as? String ?? "warn"
            )
        }
    }

    private func parsePreferences(data: Data, labelerDID: String) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        preferences = root?["preferences"] as? [[String: Any]] ?? []
        for label in labels {
            let preference = preferences.last { item in
                item["$type"] as? String == "app.bsky.actor.defs#contentLabelPref"
                    && item["label"] as? String == label.id
                    && (item["labelerDid"] as? String == labelerDID || item["labelerDid"] == nil)
            }
            visibility[label.id] = preference?["visibility"] as? String ?? label.defaultVisibility
        }
    }
}

#endif
