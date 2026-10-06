// Run the actual Swift edition assembler and emit the complete serving JSON.
// stdin/stdout are the fixture protocol; no hosted services or stores are used.
import Foundation

@main
struct EditionOracle {
  struct AccountCandidate: Decodable {
    var account: WireTalkedAboutAccount
    var distinctStoryCount: Int
    var distinctSpeakerCount: Int
    var bestStoryRank: Int
    var latestMentionAt: Date?
    var candidate: WireTalkedAboutAccountCandidate {
      WireTalkedAboutAccountCandidate(account: account, distinctStoryCount: distinctStoryCount,
        distinctSpeakerCount: distinctSpeakerCount, bestStoryRank: bestStoryRank, latestMentionAt: latestMentionAt)
    }
  }
  struct Request: Decodable { var items: [WireFeedItem]; var accounts: [AccountCandidate]; var asOf: Date }
  static func main() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let request = try decoder.decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let edition = WireEditionAssembler.assemble(generationID: "fixture", generatedAt: request.asOf,
      language: "und", source: .ranked, degraded: false, rankedItems: request.items,
      talkedAboutAccountCandidates: request.accounts.map(\.candidate))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(edition))
  }
}
