import Foundation

struct UserInputBoardReference: Equatable, Sendable {
    let strongRef: StrongRef
    let tags: [UserInputTag]
}
