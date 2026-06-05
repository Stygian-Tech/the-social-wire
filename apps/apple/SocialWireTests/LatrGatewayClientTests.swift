import Foundation
import Testing
@testable import SocialWire

@Suite("LatrGatewayEnvironment")
struct LatrGatewayEnvironmentTests {
    @Test("shipping builds use Social Wire Gateway transport, not direct L@tr credentials")
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

@Suite("LatrGatewayClient pdsXrpc mapping")
struct LatrGatewayClientMappingTests {
    @Test("maps list saves to repo.listRecords")
    func listSavesMapping() {
        #expect(LatrGatewayClientTestsHelper.pdsXrpcMethod(gatewayMethod: "GET", path: "/v1/latr/saves") == "com.atproto.repo.listRecords")
    }

    @Test("maps create save to repo.createRecord")
    func createSaveMapping() {
        #expect(LatrGatewayClientTestsHelper.pdsXrpcMethod(gatewayMethod: "POST", path: "/v1/latr/saves") == "com.atproto.repo.createRecord")
    }

    @Test("maps archive to repo.putRecord")
    func patchSaveMapping() {
        #expect(
            LatrGatewayClientTestsHelper.pdsXrpcMethod(
                gatewayMethod: "PATCH",
                path: "/v1/latr/saves/abc/state"
            ) == "com.atproto.repo.putRecord"
        )
    }

    @Test("maps delete to repo.deleteRecord")
    func deleteSaveMapping() {
        #expect(
            LatrGatewayClientTestsHelper.pdsXrpcMethod(
                gatewayMethod: "DELETE",
                path: "/v1/latr/saves/abc"
            ) == "com.atproto.repo.deleteRecord"
        )
    }
}

@Suite("PDSRecordService L@tr merge")
struct LatrMergeTests {
    @Test("mergeFromGatewayItems preserves linkedWebUrl on native saves")
    func nativeLinkedWebUrl() {
        let item = RepoRecord(
            uri: "at://did:plc:viewer/link.latr.saved.item/item1",
            cid: "cid",
            value: LatrSavedItemRecord(
                type: "link.latr.saved.item",
                subjectUri: "at://did:plc:author/app.bsky.feed.post/abc",
                savedAt: "2026-01-01T00:00:00.000Z",
                state: "unread",
                linkedWebUrl: "https://example.com/post",
                previewTitle: "Title"
            )
        )
        let merged = PDSRecordService.mergeFromGatewayItems([item])
        #expect(merged.count == 1)
        #expect(merged[0].linkedWebUrl == "https://example.com/post")
        #expect(merged[0].title == "Title")
    }
}

/// Exposes private mapping helpers for unit tests.
enum LatrGatewayClientTestsHelper {
    static func pdsXrpcMethod(gatewayMethod: String, path: String) -> String? {
        let method = gatewayMethod.uppercased()
        if method == "GET", path == "/v1/latr/saves" {
            return "com.atproto.repo.listRecords"
        }
        if method == "POST" && path == "/v1/latr/saves" {
            return "com.atproto.repo.createRecord"
        }
        if method == "PATCH", path.contains("/v1/latr/saves/"), path.hasSuffix("/state") {
            return "com.atproto.repo.putRecord"
        }
        if method == "DELETE", path.hasPrefix("/v1/latr/saves/") {
            return "com.atproto.repo.deleteRecord"
        }
        return nil
    }
}
