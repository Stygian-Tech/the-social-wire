#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class RemoteVerificationStore {
    typealias Loader = @Sendable (_ issuer: String, _ cursor: String?) async throws -> Data

    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var verifiedSubjectsByIssuer: [String: Set<String>] = [:]
    @ObservationIgnored private var loadedIssuers: Set<String> = []

    init(loader: @escaping Loader = { issuer, cursor in
        var parameters = [
            "repo": issuer,
            "collection": "app.bsky.graph.verification",
            "limit": "100",
        ]
        if let cursor { parameters["cursor"] = cursor }
        return try await ATProtoPublicRepository.listRecords(parameters: parameters)
    }) {
        self.loader = loader
    }

    func isVerified(subjectDID: String, verifierDIDs: [String]) async -> Bool {
        for issuer in verifierDIDs {
            await load(issuer: issuer)
            if verifiedSubjectsByIssuer[issuer]?.contains(subjectDID) == true {
                return true
            }
        }
        return false
    }

    private func load(issuer: String) async {
        guard loadedIssuers.insert(issuer).inserted else { return }
        var subjects: Set<String> = []
        var cursor: String?
        repeat {
            guard let data = try? await loader(issuer, cursor),
                  let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
            subjects.formUnion(response.records.map(\.value.subject))
            cursor = response.cursor
        } while cursor != nil
        verifiedSubjectsByIssuer[issuer] = subjects
    }
}

private extension RemoteVerificationStore {
    struct Response: Decodable {
        let cursor: String?
        let records: [Record]
    }

    struct Record: Decodable {
        let value: Value
    }

    struct Value: Decodable {
        let subject: String
    }
}

#endif
