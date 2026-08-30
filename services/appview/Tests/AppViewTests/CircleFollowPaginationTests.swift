import Testing

@testable import AppView

@Suite("Your Circle follow pagination")
struct CircleFollowPaginationTests {
  @Test("accepts a complete single-page response")
  func singlePage() throws {
    let cursor = try CircleFollowPagination.nextCursor(
      current: nil,
      returned: nil,
      actorDID: "did:plc:alice"
    )
    #expect(cursor == nil)
  }

  @Test("advances and completes a multi-page response")
  func multiplePages() throws {
    let next = try CircleFollowPagination.nextCursor(
      current: nil,
      returned: "page-2",
      actorDID: "did:plc:alice"
    )
    #expect(next == "page-2")
    #expect(try CircleFollowPagination.nextCursor(
      current: next,
      returned: nil,
      actorDID: "did:plc:alice"
    ) == nil)
  }

  @Test("rejects a repeated non-terminal cursor")
  func repeatedCursor() {
    #expect(throws: CircleGraphSnapshotError.incompleteFollowRead(actorDID: "did:plc:alice")) {
      _ = try CircleFollowPagination.nextCursor(
        current: "page-2",
        returned: "page-2",
        actorDID: "did:plc:alice"
      )
    }
  }
}
