import SwiftUI

struct ListsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    private let onListSourceTap: (ReaderListSource) -> Void
    @State private var refreshFeedback = 0

    init(onListSourceTap: @escaping (ReaderListSource) -> Void) {
        self.onListSourceTap = onListSourceTap
    }

    var body: some View {
        List {
            ForEach(appModel.visibleReaderListSources) { source in
                ReaderTopLevelFeedRow(source: source) {
                    onListSourceTap(source)
                }
            }
        }
        .readerListCanvas()
        .refreshable {
            await appModel.refreshAll()
            refreshFeedback += 1
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: refreshFeedback)
    }
}
