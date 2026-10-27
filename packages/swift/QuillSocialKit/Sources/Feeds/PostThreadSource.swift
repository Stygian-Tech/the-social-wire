import ATProtoCore

public protocol PostThreadSource: Sendable {
    func thread(uri: ATURI) async throws -> PostThread
}
