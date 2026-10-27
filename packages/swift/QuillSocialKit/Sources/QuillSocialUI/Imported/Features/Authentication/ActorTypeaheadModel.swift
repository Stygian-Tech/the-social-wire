#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class ActorTypeaheadModel {
    private(set) var results: [ActorTypeaheadResult] = []
    private var searchTask: Task<Void, Never>?

    func search(_ query: String) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !query.contains("://") else {
            results = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            var components = URLComponents(string: "https://typeahead.waow.tech/xrpc/tech.waow.typeahead.searchActors")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "6"),
            ]
            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            request.setValue("Quill/0.1", forHTTPHeaderField: "X-Client")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode,
                  let decoded = try? JSONDecoder().decode(Response.self, from: data),
                  !Task.isCancelled else { return }
            results = decoded.actors
        }
    }

    func clear() {
        searchTask?.cancel()
        results = []
    }
}

private extension ActorTypeaheadModel {
    struct Response: Decodable {
        let actors: [ActorTypeaheadResult]
    }
}

#endif
