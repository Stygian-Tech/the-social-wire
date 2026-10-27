#if os(iOS)
import Foundation
import SwiftUI

enum CodeSyntaxHighlighter {
    static func highlighted(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)

        apply(#"(?m)//.*$|(?m)#.*$|(?s)/\*.*?\*/"#, color: .secondary, to: &result, source: code)
        apply(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .green, to: &result, source: code)
        apply(#"\b(?:true|false|null|nil|self|Self)\b"#, color: .orange, to: &result, source: code)
        apply(#"\b\d+(?:\.\d+)?\b"#, color: .purple, to: &result, source: code)

        let keywords = keywordPattern(for: language)
        apply("\\b(?:\(keywords))\\b", color: .accentColor, to: &result, source: code)
        return result
    }

    private static func apply(
        _ pattern: String,
        color: Color,
        to value: inout AttributedString,
        source: String
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              !source.isEmpty else { return }
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let sourceRange = Range(match.range, in: source),
                  let range = Range(sourceRange, in: value) else { continue }
            value[range].foregroundColor = color
        }
    }

    private static func keywordPattern(for language: String?) -> String {
        switch language?.lowercased() {
        case "swift":
            "actor|associatedtype|async|await|break|case|catch|class|continue|default|defer|do|else|enum|extension|for|func|guard|if|import|in|init|let|nonisolated|private|protocol|public|repeat|return|some|static|struct|switch|throw|throws|try|typealias|var|where|while"
        case "js", "javascript", "jsx", "ts", "typescript", "tsx":
            "async|await|break|case|catch|class|const|continue|default|delete|do|else|export|extends|finally|for|from|function|if|import|in|instanceof|interface|let|new|of|return|static|switch|throw|try|typeof|var|while|yield"
        case "py", "python":
            "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield"
        case "go":
            "break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var"
        case "rs", "rust":
            "as|async|await|break|const|continue|crate|dyn|else|enum|extern|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|static|struct|super|trait|type|unsafe|use|where|while"
        default:
            "break|case|class|const|continue|default|else|enum|false|for|func|function|if|import|let|nil|null|private|public|return|static|struct|switch|true|type|var|while"
        }
    }
}

#endif
