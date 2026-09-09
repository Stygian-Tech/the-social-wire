import Foundation
import Testing
@testable import ReadStateCore

@Test func packingRejectsAnOversizedGenerationBeforeUpload() throws {
  let operation = ReadStateOperation(actionId: "one", sequence: 1, state: .read,
    actedAt: "2026-09-08T00:00:00Z", subjectUris: ["story"])
  let chunks = try ReadStateDensePacking.chunks(operations: [operation], viewerDid: "did:plc:viewer")
  #expect(throws: ReadStateError.sizeLimit) {
    try ReadStateDensePacking.validateGeneration(chunks: chunks, viewerDid: "did:plc:viewer",
      existingChunkCount: 4096)
  }
  #expect(throws: ReadStateError.sizeLimit) {
    try ReadStateDensePacking.validateGeneration(chunks: chunks, viewerDid: "did:plc:viewer",
      existingBytes: 16 * 1024 * 1024)
  }
}

@Test func unknownNestedFieldsPreventLossyRepacking() throws {
  let json = #"{"$type":"app.thesocialwire.readStateChunk","version":1,"operations":[{"actionId":"test","sequence":1,"state":"read","actedAt":"2026-09-08T00:00:00Z","selection":"exact","subjectUris":["story"],"futureExtension":true}]}"#
  let chunk = try JSONDecoder().decode(ReadStateChunk.self, from: Data(json.utf8))
  #expect(!chunk.allowsRepacking)
  try ReadStateValidation.validate(chunk, viewerDid: "did:plc:viewer")
}
