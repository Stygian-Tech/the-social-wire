// Run actual Finance/Sports rankers; emit ordered IDs without claiming resolver parity.
// stdin/stdout are the fixture protocol; no hosted services or stores are used.
import Foundation

@main
struct DomainRankingOracle {
  struct Request: Decodable {
    var finance: [FinanceRankCandidate]
    var sports: [SportsRankCandidate]
    var instrumentIDs: [String]
    var sectorIDs: [String]
    var followIDs: [String]
    var muteIDs: [String]
    var entities: [SportsEntity]
    var reserveGlobal: Bool
  }
  struct Response: Encodable { var finance: [String]; var sports: [String] }
  static func main() throws {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let request = try decoder.decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let finance = FinanceRanker.rank(candidates: request.finance, instrumentIDs: Set(request.instrumentIDs),
      sectorIDs: Set(request.sectorIDs), reserveGlobal: request.reserveGlobal)
    let sports = SportsRanker.rank(candidates: request.sports, followIDs: Set(request.followIDs),
      muteIDs: Set(request.muteIDs), entities: request.entities, reserveGlobal: request.reserveGlobal)
    FileHandle.standardOutput.write(try JSONEncoder().encode(Response(finance: finance.map { candidate in candidate.item.itemID }, sports: sports.map { candidate in candidate.item.itemID })))
  }
}
