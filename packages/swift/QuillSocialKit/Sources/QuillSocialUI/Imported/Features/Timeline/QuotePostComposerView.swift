#if os(iOS)
import SwiftUI

struct QuotePostComposerView: View {
    @Bindable var model: PostActionsModel

    var body: some View {
        PostComposerView(context: .quote(model.post)) {
            model.didPublishQuote()
        }
    }
}

#endif
