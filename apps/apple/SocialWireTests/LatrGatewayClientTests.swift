import Foundation
import LatrKit
import Testing
@testable import SocialWire

@Suite("LatrGatewayEnvironment")
struct LatrGatewayEnvironmentTests {
    @Test("shipping builds use Social Wire Gateway transport")
    func shippingUsesGatewayTransport() {
        #expect(LatrGatewayEnvironment.usesDirectExternalGateway == false)
        #expect(LatrGatewayEnvironment.developerClientId == nil)
        #expect(LatrGatewayEnvironment.developerApiKey == nil)
        #expect(LatrGatewayEnvironment.officialClientCredential == nil)
        #expect(LatrGatewayEnvironment.transportBaseURL == SocialWireAPIEnvironment.baseURL)
    }

    @Test("proof base URL is a valid HTTPS origin")
    func proofBaseURLIsHTTPS() {
        let url = LatrGatewayEnvironment.proofBaseURL
        #expect(url.scheme == "https")
        #expect(url.host?.isEmpty == false)
    }
}

@Suite("L@tr bookmark proof pools")
struct LatrBookmarkProofPoolTests {
    @Test("a prepared upstream proof pool is byte-stable across nonce retries")
    func preparedProofPoolIsPreserved() throws {
        let proofPool = "proof-one,proof-two,proof-three"
        var initial = URLRequest(url: try #require(URL(string: "https://api.thesocialwire.app/xrpc/test")))
        var retry = URLRequest(url: try #require(URL(string: "https://api.thesocialwire.app/xrpc/test")))

        LatrGatewayClient.applyPreparedUpstreamProof(proofPool, to: &initial)
        LatrGatewayClient.applyPreparedUpstreamProof(proofPool, to: &retry)
        LatrGatewayClient.applyPreparedAttestation(
            receipt: "attestation-receipt",
            bodyCarriesUpstreamProof: false,
            to: &initial
        )
        LatrGatewayClient.applyPreparedAttestation(
            receipt: "attestation-receipt",
            bodyCarriesUpstreamProof: false,
            to: &retry
        )

        #expect(initial.value(forHTTPHeaderField: "X-ATProto-Upstream-DPoP") == proofPool)
        #expect(retry.value(forHTTPHeaderField: "X-ATProto-Upstream-DPoP") == proofPool)
        #expect(
            initial.value(forHTTPHeaderField: "X-ATProto-Session-Attestation-Receipt")
                == retry.value(forHTTPHeaderField: "X-ATProto-Session-Attestation-Receipt")
        )
    }

    @Test("receipt and migration marker accompany the prepared body proof pool")
    func preparedAttestationHeaders() throws {
        var request = URLRequest(
            url: try #require(URL(string: "https://api.thesocialwire.app/xrpc/link.latr.bookmarks.migrateLegacy"))
        )

        LatrGatewayClient.applyPreparedAttestation(
            receipt: "attestation-receipt",
            bodyCarriesUpstreamProof: true,
            to: &request
        )

        #expect(
            request.value(forHTTPHeaderField: "X-ATProto-Session-Attestation-Receipt")
                == "attestation-receipt"
        )
        #expect(
            request.value(forHTTPHeaderField: "X-ATProto-Upstream-DPoP-Prepared") == "true"
        )
    }

    @Test("attestation-required migration refresh discards one pool and caps regeneration")
    @MainActor
    func attestationRestartCap() async throws {
        var preparedReceipts: [String] = []
        var preparedPools: [String] = []
        var pdsNonce = "nonce-before-428"

        let value: String = try await LatrGatewayClient.performAttestationCeremonies { ceremony in
            preparedReceipts.append("receipt-\(ceremony + 1)")
            preparedPools.append("proof-pool-\(ceremony + 1)")
            if ceremony == 0 {
                #expect(pdsNonce == "nonce-before-428")
                return .refreshRequired
            }
            pdsNonce = "nonce-after-route"
            return .success("completed")
        }

        #expect(value == "completed")
        #expect(preparedReceipts == ["receipt-1", "receipt-2"])
        #expect(preparedPools == ["proof-pool-1", "proof-pool-2"])

        var exhaustedAttempts = 0
        await #expect(throws: LatrGatewayClient.AttestationCeremonyLimitError.exhausted) {
            let _: String = try await LatrGatewayClient.performAttestationCeremonies { _ in
                exhaustedAttempts += 1
                return .refreshRequired
            }
        }
        #expect(exhaustedAttempts == 2)
    }

    @Test("all six NSIDs use the finalized ordered proof budgets")
    func proofBudgets() {
        #expect(total(.listBookmarks) == 9)
        #expect(total(.getBookmark) == 9)
        #expect(total(.saveBookmark) == 11)
        #expect(total(.setBookmarkState) == 3)
        #expect(total(.deleteBookmark) == 3)
        #expect(total(.migrateBookmarks) == 90)
    }

    @Test("migration ends with the applyWrites proof pool")
    func migrationOrdering() {
        let specs = LatrGatewayClient.proofSpecs(for: .migrateBookmarks)
        #expect(specs.map(\.nsid) == [
            "com.atproto.repo.listRecords",
            "com.atproto.repo.getRecord",
            "com.atproto.repo.applyWrites",
        ])
        #expect(specs.last?.httpMethod == "POST")
        #expect(specs.last?.count == 25)
    }

    private func total(_ method: LatrXRPCMethod) -> Int {
        LatrGatewayClient.proofSpecs(for: method).reduce(0) { $0 + $1.count }
    }
}
