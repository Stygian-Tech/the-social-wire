import SwiftUI

struct ArticleListCard<Label: View>: View {
    let action: () -> Void
    private let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.thinMaterial, in: .rect(cornerRadius: 16))
                .clipShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
