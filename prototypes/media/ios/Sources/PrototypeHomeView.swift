import SwiftUI

struct PrototypeHomeView: View {
    @State private var story: SampleMedia?
    @State private var photo: SampleMedia?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Prototype · Sample Content").font(.caption).foregroundStyle(.secondary)
                Text("Stories").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 17) {
                        ForEach(SampleMedia.all) { item in
                            Button {
                                story = item
                            } label: {
                                VStack(spacing: 8) {
                                    BundledImage(name: "avatar\(item.id)").scaledToFill()
                                        .frame(width: 62, height: 62).clipShape(Circle())
                                        .padding(4).overlay(Circle().stroke(.purple, lineWidth: 2))
                                    Text(item.name.components(separatedBy: " ")[0]).font(.caption).foregroundStyle(.primary)
                                }
                            }
                            .accessibilityLabel("View \(item.name)'s Story")
                        }
                    }.padding(3)
                }.scrollIndicators(.hidden)
                Text("Following").font(.headline)
                ForEach([SampleMedia.all[0], SampleMedia.all[3]]) { item in
                    PrototypeFeedCard(item: item) { photo = item }
                }
            }.padding()
        }
        .navigationTitle("Home")
        .fullScreenCover(item: $story) { item in PrototypeStoryView(startIndex: item.id) }
        .sheet(item: $photo) { item in PrototypePhotoView(items: SampleMedia.all, startIndex: item.id) }
    }
}
