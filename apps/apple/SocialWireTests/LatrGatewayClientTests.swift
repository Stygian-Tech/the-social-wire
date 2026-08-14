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
