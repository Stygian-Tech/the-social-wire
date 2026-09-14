import Testing
import WireCore
@testable import WireCorpusEdge

@Suite("Edition cache raw membership proof")
struct WireEditionCacheProofTests {
  private let revision = """
    ["generation","version",10]
    ["module","top","v1"]
    ["module","general","v2"]
    ["item","top",0,"a","v1"]
    ["item","top",1,"b","v2"]
    ["item","general",0,"a","v1"]
    ["account",0,"did:example:a","v1"]
    ["continuation",true]
    """

  @Test("missing raw stories and duplicates fail even when the authoritative revision returns unchanged")
  func subsetABA() {
    let complete = WireEditionCacheProof(modulePrefix: "", moduleKeys: ["top", "general"],
      stories: [["top", "a"], ["top", "b"], ["general", "a"]], accounts: ["did:example:a"], hasMore: true)
    #expect(complete.matches(revision: revision, region: nil))
    let subset = WireEditionCacheProof(modulePrefix: "", moduleKeys: ["top", "general"],
      stories: [["top", "a"], ["general", "a"]], accounts: ["did:example:a"], hasMore: true)
    #expect(!subset.matches(revision: revision, region: nil))
    let missingModuleCopy = WireEditionCacheProof(modulePrefix: "", moduleKeys: ["top", "general"],
      stories: [["top", "a"], ["top", "b"]], accounts: ["did:example:a"], hasMore: true)
    #expect(!missingModuleCopy.matches(revision: revision, region: nil))
  }

  @Test("proof includes raw accounts, modules and continuation before presentation thresholds")
  func presentationThresholds() {
    // One raw account is intentionally omitted from the assembled edition (<4),
    // but still belongs in the proof. The same applies to capped story arrays.
    let missingProfile = WireEditionCacheProof(modulePrefix: "", moduleKeys: ["top", "general"],
      stories: [["top", "a"], ["top", "b"], ["general", "a"]], accounts: [], hasMore: true)
    #expect(!missingProfile.matches(revision: revision, region: nil))
    let missingModule = WireEditionCacheProof(modulePrefix: "", moduleKeys: ["top"],
      stories: [["top", "a"], ["top", "b"], ["general", "a"]], accounts: ["did:example:a"], hasMore: true)
    #expect(!missingModule.matches(revision: revision, region: nil))
    let wrongContinuation = WireEditionCacheProof(modulePrefix: "", moduleKeys: ["top", "general"],
      stories: [["top", "a"], ["top", "b"], ["general", "a"]], accounts: ["did:example:a"], hasMore: false)
    #expect(!wrongContinuation.matches(revision: revision, region: nil))
  }
}
