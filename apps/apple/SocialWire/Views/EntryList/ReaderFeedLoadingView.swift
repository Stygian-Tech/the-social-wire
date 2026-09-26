import SwiftUI

struct ReaderFeedLoadingView: View {
    var body: some View {
        ProgressView("Loading Articles")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
