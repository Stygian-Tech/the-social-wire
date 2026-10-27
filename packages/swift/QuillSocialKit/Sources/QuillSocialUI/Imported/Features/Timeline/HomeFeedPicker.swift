#if os(iOS)
import SwiftUI

struct HomeFeedPicker: View {
    let items: [HomeFeedItem]
    @Binding var selection: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(items) { item in
                        Button(item.title) {
                            selection = item.id
                        }
                        .font(.subheadline.weight(selection == item.id ? .semibold : .medium))
                        .foregroundStyle(selection == item.id ? Color.accentColor : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            if selection == item.id {
                                Capsule().fill(Color.accentColor.opacity(0.16))
                            }
                        }
                        .contentShape(.capsule)
                        .id(item.id)
                        .accessibilityAddTraits(selection == item.id ? .isSelected : [])
                        .accessibilityValue(selection == item.id ? "Selected" : "Not Selected")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, selectedID in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: items)
            .animation(.easeInOut(duration: 0.25), value: selection)
        }
        .frame(maxWidth: 520)
    }
}

#endif
