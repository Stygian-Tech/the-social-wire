import Foundation

actor SocialAccountPendingTransport {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var request: URLRequest?

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitForRequest() async {
        while continuation == nil { await Task.yield() }
    }

    func complete() {
        guard let request, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: (
            Data(#"{"private":"old account messages"}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        ))
    }
}
