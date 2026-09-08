import Hummingbird
import ReadStateCore

struct PDSReadStatePreparedSelection: Encodable, Sendable, ResponseEncodable {
  let actedAt: String
  let selection: ReadStateOperation.Selection
  let boundaries: [ReadStateBoundary]?
  let subjectUris: [String]?
  let calendar: ReadStateCalendarSelection?
  let legacyRevision: Int64
  let manifestCid: String?
  var previewSubjectUris: [String]? = nil
}
