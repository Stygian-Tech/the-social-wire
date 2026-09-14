import Foundation
@testable import SocialWire

/// Deterministic HTTP responses; no requests leave the test process.
actor OAuthTestTransport {
    struct Reply: Sendable {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []
    private let delay: Duration

    init(_ replies: [Reply], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        // Simulate a transport that can still deliver a response after cancellation.
        if delay > .zero { try? await Task.sleep(for: delay) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

/// Simulator unit tests need no Keychain entitlement and never write real credentials.
final class OAuthTestSessionStore: OAuthSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func set(_ value: String, for key: String) { lock.withLock { values[key] = value } }
    func remove(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}
