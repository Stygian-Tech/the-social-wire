import SwiftUI

struct PrototypePodcastsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A Good Listen").font(.title3.bold())
            ForEach(["The Open Conversation", "Off the Clock", "Field Notes"], id: \.self) { title in
                HStack(spacing: 16) {
                    Image(systemName: "headphones").font(.largeTitle).frame(width: 80, height: 80)
                        .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title).font(.headline)
                        Text("Sample Podcast").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Podcasts keep their home in Media. Sample episodes demonstrate the layout; playback is not connected.")
                .font(.footnote).foregroundStyle(.secondary).padding(.top)
        }
    }
}
