import Foundation

/// A non-cooperative transport: tests decide exactly when each response arrives.
actor ReaderFeedPendingTransport {
    private var requests: [URLRequest] = []
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func waitForRequests(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }

    func complete(_ index: Int, body: String, status: Int = 200) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(returning: (
            Data(body.utf8),
            HTTPURLResponse(url: requests[index].url!, statusCode: status,
                            httpVersion: "HTTP/1.1", headerFields: nil)!
        ))
    }
}
