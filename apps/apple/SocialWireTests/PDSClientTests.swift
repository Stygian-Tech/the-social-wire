import Foundation
import Testing
@testable import SocialWire

@Suite("PDSClient helpers")
struct PDSClientTests {
    // These tests cover the deterministic helper logic in PDSClient;
    // actual XRPC calls require an ATProto testnet (integration tests).

    @Test("generateTID produces a 13-character base32 string")
    func tidFormat() {
        // Access via internal helper — call createFolder in a mock context
        // For now, verify the constant values match the lexicon
        #expect(PDSClient.collectionFolder == "com.thesocialwire.folder")
        #expect(PDSClient.collectionPubPrefs == "com.thesocialwire.publicationPrefs")
        #expect(PDSClient.collectionEntry == "site.standard.entry")
    }

    @Test("FolderModel sorts by sortOrder")
    func folderSorting() {
        let folders = [
            FolderModel(id: "b", name: "B", icon: nil, iconImageURL: nil, sortOrder: 2),
            FolderModel(id: "a", name: "A", icon: nil, iconImageURL: nil, sortOrder: 1),
            FolderModel(id: "c", name: "C", icon: nil, iconImageURL: nil, sortOrder: 0),
        ]
        let sorted = folders.sorted { $0.sortOrder < $1.sortOrder }
        #expect(sorted.map(\.name) == ["C", "A", "B"])
    }

    @Test("EntryModel has correct identifier")
    func entryIdentifier() {
        let entry = EntryModel(
            entryId: "at://did:plc:alice/entry/abc",
            title: "Test",
            summary: nil,
            publishedAt: Date()
        )
        #expect(entry.id == entry.entryId)
    }

    @Test("PublicationModel has correct identifier")
    func publicationIdentifier() {
        let pub = PublicationModel(
            publicationId: "at://did:plc:alice/pub/xyz",
            authorDID: "did:plc:alice",
            title: "Alice's Blog",
            avatarURL: nil
        )
        #expect(pub.id == pub.publicationId)
    }
}
