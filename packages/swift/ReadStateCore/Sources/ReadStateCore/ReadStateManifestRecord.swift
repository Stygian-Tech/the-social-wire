public struct ReadStateManifestRecord: Codable, Sendable, Equatable {
  public let manifest: ReadStateManifest
  public let cid: String

  public init(manifest: ReadStateManifest, cid: String) {
    self.manifest = manifest
    self.cid = cid
  }
}
