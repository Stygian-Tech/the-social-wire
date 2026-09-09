import Foundation
import ReadStateCore

struct PDSReadStateSelection: Decodable, Sendable {
    let actedAt: String
    let selection: ReadStateOperation.Selection
    let boundaries: [ReadStateBoundary]?
    let subjectUris: [String]?
    let calendar: ReadStateCalendarSelection?
    let legacyRevision: Int64
    let manifestCid: String?
    var previewSubjectUris: [String]? = nil

    func operations(state: ReadStateOperation.State, actionId: String = UUID().uuidString.lowercased()) throws -> [ReadStateOperation] {
        var result: [ReadStateOperation] = []
        if let subjectUris {
            // Size bound also holds for long synthetic RSS identifiers.
            var batch: [String] = []
            var bytes = 0
            for uri in Set(subjectUris).sorted() {
                if batch.count == 128 || bytes + uri.utf8.count > 32_768 {
                    result.append(.init(actionId: actionId, sequence: 1, state: state, actedAt: actedAt,
                        subjectUris: batch, calendar: calendar))
                    batch = []; bytes = 0
                }
                batch.append(uri); bytes += uri.utf8.count
            }
            if !batch.isEmpty { result.append(.init(actionId: actionId, sequence: 1, state: state,
                actedAt: actedAt, subjectUris: batch, calendar: calendar)) }
        } else if let boundaries {
            // A scope with many aliases can approach the record limit by itself.
            for boundary in boundaries {
                result.append(.init(actionId: actionId, sequence: 1, state: state,
                    actedAt: actedAt, boundaries: [boundary]))
            }
        }
        for operation in result { try ReadStateValidation.validate(operation) }
        return result
    }
}
