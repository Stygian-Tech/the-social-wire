import Foundation

enum NewsTabSlot: Int, CaseIterable, Hashable {
    case primaryOne
    case primaryTwo
    case primaryThree
    case primaryFour
    case transient
    case readLater
    case archive

    static let primarySlots: [Self] = [
        .primaryOne,
        .primaryTwo,
        .primaryThree,
        .primaryFour,
    ]

    var primaryIndex: Int? {
        switch self {
        case .primaryOne, .primaryTwo, .primaryThree, .primaryFour:
            rawValue
        case .transient, .readLater, .archive:
            nil
        }
    }

    /// Slots backed by the Read Later store instead of a feed.
    var savedListSource: ReaderListSource? {
        switch self {
        case .readLater:
            .readLater
        case .archive:
            .archive
        case .primaryOne, .primaryTwo, .primaryThree, .primaryFour, .transient:
            nil
        }
    }
}
