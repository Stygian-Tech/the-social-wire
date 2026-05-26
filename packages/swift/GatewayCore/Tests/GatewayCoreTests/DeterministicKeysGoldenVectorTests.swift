import Testing
@testable import GatewayCore

@Suite("DeterministicKeys golden vectors")
struct DeterministicKeysGoldenVectorTests {
  @Test("entryReadStateRKey matches canonical base32")
  func entryReadStateRKeyMatchesCanonical() {
    let subjectURI = "at://did:plc:alice/site.standard.document/abc123"
    let rkey = DeterministicKeys.entryReadStateRKey(subjectURI: subjectURI)
    #expect(rkey == "JPFAJWZIZ7VWQJ3CR2L7PEPRNZBZ6LJ7MKKO3RKWB642BF64NBXQ")
  }

  @Test("legacy hex read-state keys differ from canonical")
  func legacyHexDiffersFromCanonical() {
    let subjectURI = "at://did:plc:alice/site.standard.document/abc123"
    let canonical = DeterministicKeys.entryReadStateRKey(subjectURI: subjectURI)
    let legacy = DeterministicKeys.legacyHexEntryReadStateRKey(subjectURI: subjectURI)
    #expect(canonical != legacy)
    #expect(legacy == "4bca04db28cfeb6827628e97f791f16e439f2d3f6294edc5560fb9a097dc686f")
  }
}
