#if os(iOS)
import Foundation

struct AccountLabelerServiceResponse: Decodable, Sendable {
    let views: [View]

    func displayNames(preferredLanguageCode: String?) -> [String: String] {
        guard let definitions = views.first?.policies?.labelValueDefinitions else { return [:] }
        return definitions.reduce(into: [:]) { displayNames, definition in
            guard let locale = definition.locales.first(where: {
                $0.lang == preferredLanguageCode
            }) ?? definition.locales.first(where: {
                $0.lang == "en"
            }) ?? definition.locales.first else {
                return
            }
            // Labeler responses can contain repeated definitions. Preserve the first
            // definition instead of trapping while constructing the dictionary.
            if displayNames[definition.identifier] == nil {
                displayNames[definition.identifier] = locale.name
            }
        }
    }
}

extension AccountLabelerServiceResponse {
    struct View: Decodable, Sendable {
        let policies: Policies?
    }

    struct Policies: Decodable, Sendable {
        let labelValueDefinitions: [Definition]?
    }

    struct Definition: Decodable, Sendable {
        let identifier: String
        let locales: [Localization]
    }

    struct Localization: Decodable, Sendable {
        let lang: String
        let name: String
    }
}

#endif
