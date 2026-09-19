import Foundation

enum NewsTabSlot: Int, CaseIterable, Hashable {
    case primaryOne
    case primaryTwo
    case primaryThree
    case primaryFour
    case transient
    case readLater

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
        case .transient, .readLater:
            nil
        }
    }
}
