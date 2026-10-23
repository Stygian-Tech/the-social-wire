import SwiftUI

struct PrototypePhotoView: View {
    let items: [SampleMedia]
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    init(items: [SampleMedia], startIndex: Int) {
        self.items = items
        // The initial selection seeds this presentation's independent navigation.
        _index = State(initialValue: startIndex)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                BundledImage(name: "photo\(items[index].id)").scaledToFit()
                VStack(spacing: 8) {
                    Text(items[index].name).font(.headline)
                    Text(items[index].caption).font(.subheadline)
                    Text("Sample Photo · \(items[index].photoSource)").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal)
                HStack {
                    Button("Previous", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0)
                    Spacer()
                    Text("\(index + 1) / \(items.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { index += 1 }.disabled(index == items.count - 1)
                }.padding()
                Spacer(minLength: 0)
            }
            .navigationTitle("Photo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
