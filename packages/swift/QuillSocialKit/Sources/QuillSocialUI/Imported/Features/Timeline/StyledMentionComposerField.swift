#if os(iOS)
import Foundation
import SwiftUI

@available(iOS 26, *)
struct StyledMentionComposerField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    let resolvedMentions: [String: String]
    let focus: FocusState<UUID?>.Binding
    let draftID: UUID
    let accentColor: Color
    let maximumHeight: CGFloat
    let selectMention: (_ handle: String, _ did: String) -> Void

    @State private var typeahead = ActorTypeaheadModel()
    @State private var styledText: AttributedString
    @State private var selection = AttributedTextSelection()

    init(
        prompt: LocalizedStringKey,
        text: Binding<String>,
        resolvedMentions: [String: String],
        focus: FocusState<UUID?>.Binding,
        draftID: UUID,
        accentColor: Color = .accentColor,
        maximumHeight: CGFloat = 320,
        selectMention: @escaping (_ handle: String, _ did: String) -> Void
    ) {
        self.prompt = prompt
        _text = text
        self.resolvedMentions = resolvedMentions
        self.focus = focus
        self.draftID = draftID
        self.accentColor = accentColor
        self.maximumHeight = maximumHeight
        self.selectMention = selectMention
        _styledText = State(initialValue: AttributedString(text.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if styledText.characters.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                ComposerTextEditorLayout(text: text, maximumHeight: maximumHeight) {
                    TextEditor(text: $styledText, selection: $selection)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.never)
                        .focused(focus, equals: draftID)
                        .accessibilityLabel(Text(prompt))
                        .accessibilityIdentifier("composer-editor-\(draftID)")
                }
            }
                .onChange(of: styledText) { _, value in
                    let plainText = String(value.characters)
                    if text != plainText {
                        text = plainText
                    }
                    applyFacetStyling()
                    if let query = mentionQuery(in: value) {
                        typeahead.search(query)
                    } else {
                        typeahead.clear()
                    }
                }
                .onChange(of: text) { _, value in
                    guard String(styledText.characters) != value else { return }
                    styledText = AttributedString(value)
                    applyFacetStyling()
                }
                .onChange(of: resolvedMentions) { _, _ in
                    applyFacetStyling()
                }
                .onChange(of: accentColor) { _, _ in
                    applyFacetStyling()
                }
                .task { applyFacetStyling() }

            if !typeahead.results.isEmpty {
                ForEach(typeahead.results.prefix(4)) { actor in
                    Button {
                        replaceMention(with: actor.handle)
                        selectMention(actor.handle, actor.did)
                        typeahead.clear()
                    } label: {
                        HStack(spacing: 8) {
                            AsyncImage(url: actor.avatar) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(.circle)

                            Text(actor.displayName ?? actor.handle)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(verbatim: "@\(actor.handle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func mentionQuery(in value: AttributedString) -> String? {
        mentionQuery(in: String(value.characters))
    }

    private func mentionQuery(in value: String) -> String? {
        guard let token = value.split(whereSeparator: { $0.isWhitespace }).last,
              token.first == "@", token.count > 1 else { return nil }
        return String(token.dropFirst())
    }

    private func replaceMention(with handle: String) {
        guard let range = text.range(of: #"@[^\s@]*$"#, options: .regularExpression) else { return }
        text.replaceSubrange(range, with: "@\(handle) ")
    }

    private func applyFacetStyling() {
        let plainText = String(styledText.characters)
        var updated = styledText
        let completeRange = updated.startIndex..<updated.endIndex
        updated[completeRange].foregroundColor = nil

        styleMatches(#"https?:\/\/[^\s<>`]+"#, in: plainText, attributedText: &updated)
        styleMatches(#"\[[^\]\n]+\]\(https?:\/\/[^\s)]+\)"#, in: plainText, attributedText: &updated)
        styleMatches(#"(?<![\p{L}\p{N}_])#[\p{L}\p{N}_]+"#, in: plainText, attributedText: &updated)
        styleMatches(#"(?<![\p{L}\p{N}_])\$[\p{L}][\p{L}\p{N}]{0,14}"#, in: plainText, attributedText: &updated)

        for handle in resolvedMentions.keys {
            let escapedHandle = NSRegularExpression.escapedPattern(for: handle)
            styleMatches(
                #"(?<![\p{L}\p{N}_.-])@"# + escapedHandle + #"(?![\p{L}\p{N}_.-])"#,
                in: plainText,
                attributedText: &updated,
                options: [.caseInsensitive]
            )
        }

        if updated != styledText {
            styledText = updated
        }
    }

    private func styleMatches(
        _ pattern: String,
        in plainText: String,
        attributedText: inout AttributedString,
        options: NSRegularExpression.Options = []
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let matches = expression.matches(
            in: plainText,
            range: NSRange(plainText.startIndex..., in: plainText)
        )
        for match in matches {
            guard let stringRange = Range(match.range, in: plainText),
                  let attributedRange = Range(stringRange, in: attributedText) else { continue }
            attributedText[attributedRange].foregroundColor = accentColor
        }
    }
}

#endif
