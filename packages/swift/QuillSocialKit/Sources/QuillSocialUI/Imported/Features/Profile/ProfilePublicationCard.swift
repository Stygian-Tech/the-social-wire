#if os(iOS)
import SwiftUI

struct ProfilePublicationCard: View {
    let publication: ProfileModel.Publication

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AsyncImage(url: publication.logoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "newspaper.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 52, height: 52)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(publication.name)
                        .font(.headline)
                    if let host = publication.url?.host() {
                        Text(host)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let description = publication.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = publication.url {
                Link(destination: url) {
                    Label("View Publication", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ThemeChipButtonStyle())
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.separator, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
    }
}

#endif
