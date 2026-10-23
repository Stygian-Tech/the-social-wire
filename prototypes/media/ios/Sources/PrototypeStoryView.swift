import SwiftUI

struct PrototypeStoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    init(startIndex: Int) { _index = State(initialValue: startIndex) }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BundledImage(name: "photo\(index)").scaledToFit()
            VStack(spacing: 20) {
                HStack(spacing: 4) {
                    ForEach(SampleMedia.all) { item in
                        Capsule().fill(item.id <= index ? .white : .white.opacity(0.3)).frame(height: 3)
                    }
                }
                HStack {
                    BundledImage(name: "avatar\(index)").scaledToFill().frame(width: 35, height: 35).clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(SampleMedia.all[index].name).font(.subheadline.bold())
                        Text("\(SampleMedia.all[index].storySource) · Sample Story").font(.caption)
                    }
                    Spacer()
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                Spacer()
                Text(SampleMedia.all[index].caption).font(.title2.bold()).multilineTextAlignment(.center)
                HStack {
                    Button("Previous", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0)
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { index += 1 }.disabled(index == 7)
                }.padding(.top)
            }.padding(24).foregroundStyle(.white)
        }.tint(.white)
    }
}
