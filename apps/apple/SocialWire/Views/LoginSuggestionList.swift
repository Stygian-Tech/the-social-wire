import SwiftUI

struct LoginSuggestionList: View {
    let suggestions: [LoginActorSuggestion]
    let selectedIndex: Int
    let onSelect: (LoginActorSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, actor in
                Button {
                    onSelect(actor)
                } label: {
                    HStack(spacing: 12) {
                        avatar(for: actor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(actor.displayName?.isEmpty == false ? actor.displayName ?? actor.handle : actor.handle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("@\(actor.handle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(index == selectedIndex ? Color.indigo.opacity(0.12) : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Use this account to sign in")
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1) }
    }

    @ViewBuilder
    private func avatar(for actor: LoginActorSuggestion) -> some View {
        Group {
            if let avatar = actor.avatar, let url = URL(string: avatar) {
                CachedRemoteImage(urls: [url], maxPixelSize: 96) { Circle().fill(.quaternary) }
                    .scaledToFill()
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(.circle)
    }
}
