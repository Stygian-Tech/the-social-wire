#if os(iOS)
import Foundation
import SwiftUI

/// Native text editing and mention resolution for the iOS 18 compatibility path.
struct PlainMentionComposerField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    let focus: FocusState<UUID?>.Binding
    let draftID: UUID
    var maximumHeight: CGFloat = 320
    let selectMention: (_ handle: String, _ did: String) -> Void
    @State private var typeahead = ActorTypeaheadModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                ComposerTextEditorLayout(text: text, maximumHeight: maximumHeight) {
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.never)
                        .focused(focus, equals: draftID)
                        .accessibilityLabel(Text(prompt))
                        .accessibilityIdentifier("composer-editor-\(draftID)")
                }
            }
            .onChange(of: text) { _, value in
                if let token = value.split(whereSeparator: { $0.isWhitespace }).last,
                   token.first == "@", token.count > 1 {
                    typeahead.search(String(token.dropFirst()))
                } else {
                    typeahead.clear()
                }
            }

            ForEach(typeahead.results.prefix(4)) { actor in
                Button {
                    guard let range = text.range(of: #"@[^\s@]*$"#, options: .regularExpression) else { return }
                    text.replaceSubrange(range, with: "@\(actor.handle) ")
                    selectMention(actor.handle, actor.did)
                    typeahead.clear()
                } label: {
                    HStack(spacing: 8) {
                        AsyncImage(url: actor.avatar) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
                        }
                        .frame(width: 28, height: 28).clipShape(.circle)
                        Text(actor.displayName ?? actor.handle).foregroundStyle(.primary).lineLimit(1)
                        Text(verbatim: "@\(actor.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
