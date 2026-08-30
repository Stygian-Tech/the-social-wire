import Foundation

struct CircleGraphSnapshot: Codable, Equatable, Sendable {
  let snapshotID: UUID
  let viewerDID: String
  let directMembers: [CircleGraphMember]
  let oneHopMembers: [CircleGraphMember]
  let directCandidateCount: Int
  let oneHopCandidateCount: Int
  let generatedAt: Date

  var directWasCapped: Bool { directCandidateCount > directMembers.count }
  var oneHopWasCapped: Bool { oneHopCandidateCount > oneHopMembers.count }
}
