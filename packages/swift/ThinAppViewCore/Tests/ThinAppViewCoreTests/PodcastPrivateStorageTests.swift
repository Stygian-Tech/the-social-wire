import Foundation
import Testing

@testable import ThinAppViewCore

struct PodcastPrivateStorageTests {
  @Test func encryptsAndAuthenticatesViewerEntityAndIdentity() throws {
    let storage = try PodcastPrivateStorage(base64Key: Data(repeating: 7, count: 32).base64EncodedString())
    let plaintext = "https://feeds.example.com/private?token=private-secret"
    let sealed = try storage.seal(plaintext, viewer: "did:plc:owner", entity: "feed", id: "one")
    #expect(sealed.hasPrefix("v1."))
    #expect(!sealed.contains("private-secret"))
    #expect(try storage.open(sealed, viewer: "did:plc:owner", entity: "feed", id: "one") == plaintext)
    #expect(throws: PodcastStoreError.privateStorageUnavailable) { try storage.open(sealed, viewer: "did:plc:other", entity: "feed", id: "one") }
    #expect(throws: PodcastStoreError.privateStorageUnavailable) { try storage.open(sealed, viewer: "did:plc:owner", entity: "episode", id: "one") }
    #expect(throws: PodcastStoreError.privateStorageUnavailable) { try storage.open(sealed, viewer: "did:plc:owner", entity: "feed", id: "two") }
    #expect(throws: PodcastStoreError.privateStorageUnavailable) { try storage.open(plaintext, viewer: "did:plc:owner", entity: "feed", id: "one") }
    let other = try PodcastPrivateStorage(base64Key: Data(repeating: 8, count: 32).base64EncodedString())
    #expect(throws: PodcastStoreError.privateStorageUnavailable) { try other.open(sealed, viewer: "did:plc:owner", entity: "feed", id: "one") }
    #expect(throws: PodcastStoreError.privateStorageUnavailable) { try PodcastPrivateStorage(base64Key: "invalid") }
    #expect(throws: PodcastStoreError.privateStorageUnavailable) { try PodcastPrivateStorage(base64Key: Data(repeating: 7, count: 31).base64EncodedString()) }
  }
}
