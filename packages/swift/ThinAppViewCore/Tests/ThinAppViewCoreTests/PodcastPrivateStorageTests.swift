import Foundation
import Testing

@testable import ThinAppViewCore

struct PodcastPrivateStorageTests {
  @Test func sharedCodecSupportsConcurrentEncryptionWithUniqueNonces() async throws {
    let storage = try PodcastPrivateStorage(base64Key: Data(repeating: 7, count: 32).base64EncodedString())
    let payloads = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<16 {
        group.addTask {
          try storage.seal("private content", viewer: "did:plc:owner", entity: "feed", id: "one")
        }
      }
      var values: [String] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(Set(payloads).count == 16)
    for payload in payloads {
      #expect(try storage.open(payload, viewer: "did:plc:owner", entity: "feed", id: "one") == "private content")
    }
  }

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
