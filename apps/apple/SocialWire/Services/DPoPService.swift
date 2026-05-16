import CryptoKit
import Foundation

actor DPoPService {
    private var privateKey: P256.Signing.PrivateKey
    private var nonceByOrigin: [String: String] = [:]

    init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    func proof(method: String, url: URL, accessToken: String? = nil) throws -> String {
        let origin = originKey(for: url)
        let nonce = nonceByOrigin[origin]

        var header: [String: JSONValue] = [
            "typ": .string("dpop+jwt"),
            "alg": .string("ES256"),
            "jwk": jwkValue()
        ]

        var payload: [String: JSONValue] = [
            "jti": .string(UUID().uuidString),
            "htm": .string(method.uppercased()),
            "htu": .string(urlWithoutQueryFragment(url).absoluteString),
            "iat": .number(Double(Int(Date().timeIntervalSince1970)))
        ]

        if let nonce {
            payload["nonce"] = .string(nonce)
        }

        if let accessToken {
            let digest = SHA256.hash(data: Data(accessToken.utf8))
            payload["ath"] = .string(Data(digest).base64URLEncodedString())
        }

        let encodedHeader = try JSONEncoder().encode(header).base64URLEncodedString()
        let encodedPayload = try JSONEncoder().encode(payload).base64URLEncodedString()
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
    }

    func updateNonce(from response: HTTPURLResponse) {
        guard let nonce = response.value(forHTTPHeaderField: "DPoP-Nonce"),
              let url = response.url
        else { return }
        nonceByOrigin[originKey(for: url)] = nonce
    }

    func exportPrivateKey() -> String {
        privateKey.rawRepresentation.base64EncodedString()
    }

    func replacePrivateKey(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: data)
        else { return }
        privateKey = key
    }

    private func jwkValue() -> JSONValue {
        let publicKey = privateKey.publicKey.x963Representation
        let x = publicKey.dropFirst().prefix(32)
        let y = publicKey.dropFirst(33).prefix(32)
        return .object([
            "kty": .string("EC"),
            "crv": .string("P-256"),
            "x": .string(Data(x).base64URLEncodedString()),
            "y": .string(Data(y).base64URLEncodedString())
        ])
    }

    private func originKey(for url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "")"
    }

    private func urlWithoutQueryFragment(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
