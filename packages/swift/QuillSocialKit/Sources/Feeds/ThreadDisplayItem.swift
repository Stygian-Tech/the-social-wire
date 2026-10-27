public enum ThreadDisplayItem: Sendable, Equatable, Identifiable {
    case post(ThreadEntry)
    case showMore(parentID: String, hiddenCount: Int)

    public var id: String {
        switch self {
        case .post(let entry):
            "post:\(entry.id)"
        case .showMore(let parentID, _):
            "more:\(parentID)"
        }
    }
}
