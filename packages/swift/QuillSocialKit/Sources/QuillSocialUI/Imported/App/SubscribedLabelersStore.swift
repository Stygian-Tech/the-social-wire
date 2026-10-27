#if os(iOS)
import Foundation
import Feeds

actor SubscribedLabelersStore {
    typealias Request = @Sendable () async throws -> Data

    private let request: Request
    private var includesBluesky: Bool
    private var additionalDIDs: [String]
    private var cachedDIDs: [String]?

    init(includesBluesky: Bool, additionalDIDs: [String], request: @escaping Request) {
        self.includesBluesky = includesBluesky
        self.additionalDIDs = additionalDIDs
        self.request = request
    }

    func dids() async throws -> [String] {
        if let cachedDIDs {
            return cachedDIDs
        }

        let data = try await request()
        var seen = Set<String>()
        let result = (try AcceptedLabelers(
            preferencesData: data,
            includesBluesky: includesBluesky
        ).dids + additionalDIDs).filter { seen.insert($0).inserted }
        cachedDIDs = result
        return result
    }

    func updateConfiguration(includesBluesky: Bool, additionalDIDs: [String]) {
        self.includesBluesky = includesBluesky
        self.additionalDIDs = additionalDIDs
        cachedDIDs = nil
    }
}

#endif
