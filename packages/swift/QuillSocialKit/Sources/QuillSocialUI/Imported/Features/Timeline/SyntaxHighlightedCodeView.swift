#if os(iOS)
import SwiftUI

struct SyntaxHighlightedCodeView: View {
    let code: String
    let language: String?
    var maximumLines: Int? = nil
    var cornerRadius: CGFloat = 8
    var showsLanguage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLanguage, let language, !language.isEmpty {
                Text(language)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                Divider()
            }

            ScrollView(.horizontal) {
                Text(CodeSyntaxHighlighter.highlighted(code, language: language))
                    .font(.system(.caption, design: .monospaced))
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .lineLimit(maximumLines)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .scrollIndicators(.visible)
        }
        .background(.fill.tertiary, in: .rect(cornerRadius: cornerRadius))
        .accessibilityLabel("Code Block")
    }
}

#endif
