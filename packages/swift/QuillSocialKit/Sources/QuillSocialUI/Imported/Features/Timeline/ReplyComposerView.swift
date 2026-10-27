#if os(iOS)
import SwiftUI

struct ReplyComposerView: View {
    @Bindable var model: PostActionsModel

    var body: some View {
        PostComposerView(context: .reply(model.post)) {
            model.didPublishReply()
        }
    }
}

#endif
