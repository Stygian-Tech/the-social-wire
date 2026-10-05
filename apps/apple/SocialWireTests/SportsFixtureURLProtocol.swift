import Foundation

final class SportsFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        let status: Int
        let body: String
        if path.hasSuffix("getSportsCatalog") {
            status = 200
            body = #"{"enabled":true,"available":true,"eventsEnabled":false,"feeds":[{"id":"sports","title":"Sports","kind":"global","entityIDs":[],"description":"Global"}],"entities":[],"version":"v1"}"#
        } else if cursor != nil {
            status = 410
            body = #"{"error":"CursorExpired","message":"Expired"}"#
        } else {
            status = 200
            body = #"{"feedId":"sports","eventsEnabled":false,"items":[],"generationId":"generation","generatedAt":"2026-10-03T17:00:00Z","expiresAt":"2026-10-05T17:00:00Z","language":"en","preferenceRevision":"p","cursor":"expired","source":"generation","degraded":false}"#
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            guard let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
