import Foundation

enum ATProtoSessionDPoP {
    static let headerName = "X-ATProto-Session-DPoP"
    static let nonceHeaderName = "X-ATProto-Session-DPoP-Nonce"
    static let receiptHeaderName = "X-ATProto-Session-Attestation-Receipt"
    static let attestationRequiredHeaderName = "X-ATProto-Session-Attestation-Required"
    static let preparedUpstreamDPoPHeaderName = "X-ATProto-Upstream-DPoP-Prepared"

    static func getSessionURL(for session: AuthSession) -> URL {
        session.pdsURL.appending(path: "xrpc/com.atproto.server.getSession")
    }

    static func isNonceChallenge(_ response: HTTPURLResponse) -> Bool {
        [400, 401].contains(response.statusCode)
            && response.value(forHTTPHeaderField: nonceHeaderName) != nil
    }

    static func receipt(from response: HTTPURLResponse) -> String? {
        guard let receipt = response.value(forHTTPHeaderField: receiptHeaderName)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !receipt.isEmpty
        else { return nil }
        return receipt
    }

    static func isAttestationRequired(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 428 else { return false }
        return response.value(forHTTPHeaderField: attestationRequiredHeaderName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }
}
