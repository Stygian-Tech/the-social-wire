import Foundation

struct PodcastSearchInput {
    var query = ""
    var scope: PodcastSearchScope = .library

    func selecting(_ scope: PodcastSearchScope) -> Self {
        guard scope != self.scope else { return self }
        return Self(query: "", scope: scope)
    }
}
