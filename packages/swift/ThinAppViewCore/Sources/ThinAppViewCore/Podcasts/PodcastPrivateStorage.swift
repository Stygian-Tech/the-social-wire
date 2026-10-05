import Crypto
import Foundation

/// Versioned private storage with entity- and viewer-bound authenticated encryption.
public struct PodcastPrivateStorage: Sendable {
  private let keyBytes: Data
  public init(base64Key: String) throws {
    guard let data = Data(base64Encoded: base64Key), data.count == 32 else {
      throw PodcastStoreError.privateStorageUnavailable
    }
    keyBytes = data
  }
  public func seal(_ plaintext: String, viewer: String, entity: String, id: String) throws -> String {
    let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: SymmetricKey(data: keyBytes),
      authenticating: context(viewer: viewer, entity: entity, id: id))
    guard let combined = sealed.combined else { throw PodcastStoreError.privateStorageUnavailable }
    return "v1." + combined.base64EncodedString()
  }
  public func open(_ payload: String, viewer: String, entity: String, id: String) throws -> String {
    do {
      guard payload.hasPrefix("v1."), let bytes = Data(base64Encoded: String(payload.dropFirst(3))) else {
        throw PodcastStoreError.privateStorageUnavailable
      }
      let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: keyBytes),
        authenticating: context(viewer: viewer, entity: entity, id: id))
      guard let text = String(data: plaintext, encoding: .utf8) else { throw PodcastStoreError.privateStorageUnavailable }
      return text
    } catch { throw PodcastStoreError.privateStorageUnavailable }
  }
  private func context(viewer: String, entity: String, id: String) -> Data {
    Data("podcast-private:v1:\(viewer.utf8.count):\(viewer):\(entity):\(id)".utf8)
  }
}
