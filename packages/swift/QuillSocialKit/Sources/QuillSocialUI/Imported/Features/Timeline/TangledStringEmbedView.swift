#if os(iOS)
import Feeds
import SwiftUI

struct TangledStringEmbedView: View {
    let metadata: TangledStringEmbedMetadata
    let destination: URL

    @State private var isExpanded = false

    private var lines: [Substring] { metadata.contents.split(separator: "\n", omittingEmptySubsequences: false) }
    private var canExpand: Bool { lines.count > 10 }
    private var displayedCode: String {
        isExpanded ? metadata.contents : lines.prefix(10).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Link(destination: destination) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(.secondary)
                    Text(metadata.filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("Tangled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            }
            .buttonStyle(.plain)

            Divider()

            Group {
                if isExpanded {
                    ScrollView(.vertical) {
                        SyntaxHighlightedCodeView(
                            code: displayedCode,
                            language: language,
                            cornerRadius: 0,
                            showsLanguage: true
                        )
                    }
                    .frame(maxHeight: 450)
                } else {
                    SyntaxHighlightedCodeView(
                        code: displayedCode,
                        language: language,
                        maximumLines: 10,
                        cornerRadius: 0,
                        showsLanguage: true
                    )
                }
            }

            Divider()

            HStack(spacing: 7) {
                AsyncImage(url: metadata.authorAvatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.circle.fill").foregroundStyle(.gray)
                }
                .frame(width: 20, height: 20)
                .clipShape(.circle)

                Text(metadata.authorName ?? "Author")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if canExpand {
                    Button(isExpanded ? "Show Less" : "Show More") {
                        isExpanded.toggle()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: isExpanded)
                }

                Text("\(lines.count) lines")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5) }
        .clipShape(.rect(cornerRadius: 12))
    }

    private var language: String? {
        metadata.filename.split(separator: ".").last.map(String.init)
    }
}

#endif
