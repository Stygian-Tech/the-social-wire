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

    /// Advances the viewer PDS DPoP nonce chain before minting upstream write proofs (RFC 9449 single-use nonces).
    func advancePdsDpopNonce(
        session: AuthSession,
        collection: String = "link.latr.saved.item",
        urlSession: URLSession = .shared
    ) async {
        var listComponents = URLComponents(
            url: session.pdsURL.appending(path: "xrpc/com.atproto.repo.listRecords"),
            resolvingAgainstBaseURL: false
        )
        listComponents?.queryItems = [
            URLQueryItem(name: "repo", value: session.did),
            URLQueryItem(name: "collection", value: collection),
            URLQueryItem(name: "limit", value: "1"),
        ]
        if let listURL = listComponents?.url {
            let nonceBefore = nonceByOrigin[originKey(for: listURL)]
            await sendPdsDpopProbe(method: "GET", url: listURL, session: session, urlSession: urlSession)
            if nonceByOrigin[originKey(for: listURL)] != nonceBefore {
                return
            }
        }

        let putURL = session.pdsURL.appending(path: "xrpc/com.atproto.repo.putRecord")
        await sendPdsDpopWriteProbe(url: putURL, session: session, collection: collection, urlSession: urlSession)
    }

    private func sendPdsDpopWriteProbe(
        url: URL,
        session: AuthSession,
        collection: String,
        urlSession: URLSession
    ) async {
        let body = """
        {"repo":"\(session.did)","collection":"\(collection)","rkey":"_dpop_nonce_probe","record":{"$type":"\(collection)"}}
        """
        await sendPdsDpopProbe(
            method: "POST",
            url: url,
            session: session,
            urlSession: urlSession,
            body: Data(body.utf8)
        )
    }

    private func sendPdsDpopProbe(
        method: String,
        url: URL,
        session: AuthSession,
        urlSession: URLSession,
        body: Data? = nil
    ) async {
        func signedRequest() throws -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            request.setValue("DPoP \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                try proof(method: method, url: url, accessToken: session.accessToken),
                forHTTPHeaderField: "DPoP"
            )
            return request
        }

        guard let initial = try? signedRequest(),
              let (_, response) = try? await urlSession.data(for: initial),
              let http = response as? HTTPURLResponse
        else { return }

        updateNonce(from: http)

        guard [401, 400].contains(http.statusCode),
              http.value(forHTTPHeaderField: "DPoP-Nonce") != nil,
              let retry = try? signedRequest(),
              let (_, retryResponse) = try? await urlSession.data(for: retry),
              let retryHttp = retryResponse as? HTTPURLResponse
        else { return }

        updateNonce(from: retryHttp)
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
