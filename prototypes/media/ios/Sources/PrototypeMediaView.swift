import SwiftUI

struct PrototypeMediaView: View {
    @State private var category = "Short Videos"
    @State private var source = "All"
    @State private var selected: SampleMedia?
    private var sources: [String] { category == "Photos" ? ["All", "Bluesky", "Spark", "Grain", "Flashes"] : ["All", "Bluesky", "Spark"] }
    private var items: [SampleMedia] { SampleMedia.all.filter { source == "All" || (category == "Photos" ? $0.photoSource : $0.videoSource) == source } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Prototype · Sample Content").font(.caption).foregroundStyle(.secondary)
                Text("Sound, motion, and moments. All in one place.").font(.subheadline).foregroundStyle(.secondary)
                Picker("Media Category", selection: $category) {
                    Text("Podcasts").tag("Podcasts")
                    Text("Short Videos").tag("Short Videos")
                    Text("Photos").tag("Photos")
                }.pickerStyle(.segmented).onChange(of: category) { source = "All" }
                if category == "Podcasts" {
                    PrototypePodcastsView()
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(sources, id: \.self) { value in
                                Button(value) { source = value }
                                    .font(.caption.bold()).padding(.horizontal, 15).padding(.vertical, 9)
                                    .background(source == value ? Color.purple : Color.secondary.opacity(0.1), in: Capsule())
                                    .foregroundStyle(source == value ? .white : .primary)
                                    .accessibilityAddTraits(source == value ? .isSelected : [])
                            }
                        }
                    }.scrollIndicators(.hidden)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 23) {
                        ForEach(items) { item in
                            Button { selected = item } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    GeometryReader { geometry in
                                        BundledImage(name: "photo\(item.id)").scaledToFill()
                                            .frame(width: geometry.size.width, height: geometry.size.height)
                                            .clipped()
                                    }
                                        .frame(height: category == "Photos" ? 215 : 260)
                                        .overlay(alignment: .topLeading) {
                                            Text(category == "Photos" ? item.photoSource : item.videoSource)
                                                .font(.caption2.bold()).padding(7).background(.ultraThinMaterial, in: Capsule()).padding(9)
                                        }
                                        .overlay(alignment: .bottomLeading) {
                                            if category != "Photos" { Image(systemName: "play.fill").foregroundStyle(.white).padding(12) }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 13))
                                    Text(item.name).font(.caption.bold())
                                    Text(item.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.foregroundStyle(.primary).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Open \(category == "Photos" ? "Photo" : "Video"): \(item.caption)")
                        }
                    }
                }
            }.padding()
        }
        .navigationTitle("Media")
        .sheet(item: $selected) { item in
            if category == "Photos" {
                PrototypePhotoView(items: items, startIndex: items.firstIndex(where: { $0.id == item.id }) ?? 0)
            } else { PrototypeVideoView(item: item) }
        }
    }
}
