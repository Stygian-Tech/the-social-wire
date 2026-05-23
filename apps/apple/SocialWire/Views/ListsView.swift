import SwiftUI

struct ListsView: View {
    @Environment(SocialWireAppModel.self) private var appModel
    private let navigateToPane: (ReaderPane) -> Void

    init(navigateToPane: @escaping (ReaderPane) -> Void) {
        self.navigateToPane = navigateToPane
    }

    var body: some View {
        List {
            ForEach(ReaderListSource.allCases) { source in
                Button {
                    appModel.selectReaderListSource(source)
                    navigateToPane(.publications)
                } label: {
                    HStack {
                        Label(source.rawValue, systemImage: source.systemImage)
                        Spacer(minLength: 8)
                        if appModel.readerListSource == source {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .readerClearListRow()
                .accessibilityAddTraits(appModel.readerListSource == source ? .isSelected : [])
            }
        }
        .readerListCanvas()
    }
}
