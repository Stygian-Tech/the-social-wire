#if os(iOS)
import Foundation

struct MarkdownTextSegment: Identifiable {
    enum Kind {
        case prose(String)
        case code(language: String?, contents: String)
    }

    let id: Int
    let byteStart: Int
    let kind: Kind
}

#endif
