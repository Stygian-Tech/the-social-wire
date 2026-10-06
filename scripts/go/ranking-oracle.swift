// Run the actual Swift Wire ranker for one explicit-time JSON snapshot.
// stdin/stdout are the fixture protocol; no hosted services or stores are used.
import Foundation

private struct Input: Decodable {
  let candidates: [WireCandidate]
  let asOf: Date
  let config: WireRankingConfig?
}

@main
struct RankingOracle {
  static func main() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let input = try decoder.decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let result = try WireRanker.rank(candidates: input.candidates, asOf: input.asOf,
                                    config: input.config ?? WireRankingConfig())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(result))
  }
}
