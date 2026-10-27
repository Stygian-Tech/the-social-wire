#if os(iOS)
import Foundation

struct KlipyGIF: Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let url: URL
    let previewURL: URL
    var width: Int? = nil
    var height: Int? = nil

    var externalURL: URL {
        guard let width, let height, width > 0, height > 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "ww" || $0.name == "hh" }
        items.append(URLQueryItem(name: "ww", value: String(width)))
        items.append(URLQueryItem(name: "hh", value: String(height)))
        components.queryItems = items
        return components.url ?? url
    }
}

#endif
