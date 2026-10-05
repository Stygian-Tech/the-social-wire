import Testing
@testable import GatewayCore

@Test func onlyConfirmedEmptyPublicRecordPagesCanClearProjection() throws {
  try ATProtoAuthenticatedRepoClient.validatePublicListRecordsResponse(["records": [] as [[String: Any]]])
  #expect(throws: PublicRepoResolutionError.malformedResponse) {
    try ATProtoAuthenticatedRepoClient.validatePublicListRecordsResponse([:])
  }
  #expect(throws: PublicRepoResolutionError.malformedResponse) {
    try ATProtoAuthenticatedRepoClient.validatePublicListRecordsResponse(["records": [["uri": "at://did:plc:a/collection/key"]]])
  }
  #expect(throws: PublicRepoResolutionError.malformedResponse) {
    try ATProtoAuthenticatedRepoClient.validatePublicListRecordsResponse(["records": [] as [[String: Any]], "cursor": 42])
  }
}
