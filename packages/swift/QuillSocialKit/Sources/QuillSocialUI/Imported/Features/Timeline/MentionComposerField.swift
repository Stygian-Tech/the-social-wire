#if os(iOS)
import SwiftUI

struct MentionComposerField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    let resolvedMentions: [String: String]
    let focus: FocusState<UUID?>.Binding
    let draftID: UUID
    var accentColor: Color = .accentColor
    var maximumHeight: CGFloat = 320
    let selectMention: (_ handle: String, _ did: String) -> Void

    var body: some View {
        if #available(iOS 26, *) {
            StyledMentionComposerField(
                prompt: prompt, text: $text, resolvedMentions: resolvedMentions,
                focus: focus, draftID: draftID, accentColor: accentColor, maximumHeight: maximumHeight,
                selectMention: selectMention
            )
        } else {
            PlainMentionComposerField(
                prompt: prompt, text: $text, focus: focus, draftID: draftID, maximumHeight: maximumHeight,
                selectMention: selectMention
            )
        }
    }
}
#endif
