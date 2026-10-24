import SwiftUI

struct PrototypeFeedCard: View {
    let item: SampleMedia
    let openPhoto: () -> Void
    @State private var liked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                BundledImage(name: "avatar\(item.id)").scaledToFill().frame(width: 38, height: 38).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.subheadline.bold())
                    Text("12m · \(item.photoSource)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Collected a few little moments from the weekend. Already dreaming of going back.").font(.subheadline)
            Button(action: openPhoto) {
                BundledImage(name: "photo\(item.id)").scaledToFill().frame(height: 245).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
            }.accessibilityLabel("Open Photo: \(item.caption)")
            HStack {
                Button { liked.toggle() } label: { Label(liked ? "129" : "128", systemImage: liked ? "heart.fill" : "heart") }
                    .accessibilityLabel(liked ? "Unlike Photo" : "Like Photo")
                Spacer()
                Text("Sample Post").font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline)
            Divider().padding(.top, 8)
        }
    }
}
