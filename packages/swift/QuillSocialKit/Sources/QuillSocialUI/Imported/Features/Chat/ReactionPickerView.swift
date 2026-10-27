#if os(iOS)
import SwiftUI

struct ReactionPickerView: View {
    let select: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customReaction = ""
    @State private var showsEmojiKeyboard = false
    @FocusState private var isEmojiFieldFocused: Bool

    private let commonReactions = ["👍", "❤️", "😂", "😮", "😢", "😡", "🎉", "🔥", "👏", "🤔", "👀", "💯"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Reaction")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(commonReactions, id: \.self) { reaction in
                        Button(reaction) { choose(reaction) }
                            .font(.title2)
                            .frame(width: 48, height: 48)
                            .background(.fill.tertiary, in: .circle)
                            .accessibilityLabel("React with \(reaction)")
                    }

                    Button("More Emoji", systemImage: "plus") {
                        showsEmojiKeyboard = true
                        isEmojiFieldFocused = true
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(.fill.tertiary, in: .circle)
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)

            if showsEmojiKeyboard {
                HStack {
                    TextField("Choose any emoji", text: $customReaction)
                        .focused($isEmojiFieldFocused)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: customReaction) { _, value in
                            guard let reaction = validReaction(from: value) else { return }
                            choose(reaction)
                        }

                    Button("Add") {
                        if let reaction = validReaction(from: customReaction) {
                            choose(reaction)
                        }
                    }
                    .disabled(validReaction(from: customReaction) == nil)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private func choose(_ reaction: String) {
        select(reaction)
        dismiss()
    }

    private func validReaction(from value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count == 1 else { return nil }
        let scalars = candidate.unicodeScalars
        let isEmoji = scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji })
        return isEmoji ? candidate : nil
    }
}

#endif
