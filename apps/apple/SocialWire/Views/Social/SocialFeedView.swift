import SwiftUI

struct SocialFeedView: View {
    @State private var model: SocialTimelineModel
    let title: String
    let navigate: (SocialRoute) -> Void
    let compose: (SocialPostReference?, SocialPostReference?, SocialPostReference?) -> Void

    init(client: SocialWireSocialClient, feedURI: String? = nil, listURI: String? = nil, title: String, navigate: @escaping (SocialRoute) -> Void, compose: @escaping (SocialPostReference?, SocialPostReference?, SocialPostReference?) -> Void) {
        let model = SocialTimelineModel(client: client)
        model.feedURI = feedURI
        model.listURI = listURI
        _model = State(initialValue: model)
        self.title = title
        self.navigate = navigate
        self.compose = compose
    }

    var body: some View {
        SocialTimelineView(model: model, navigate: navigate, compose: compose).navigationTitle(title)
    }
}
