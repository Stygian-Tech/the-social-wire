public struct PDSReadStateStatus: Codable, Sendable, Equatable {
  public enum Authority: String, Codable, Sendable { case appview, pds }
  public enum MigrationState: String, Codable, Sendable { case notStarted, verified }
  public let authority: Authority
  public let migrationState: MigrationState
  public let legacyRevision: Int64
  public let manifest: ReadStateManifest?
  public let manifestCid: String?
  public let projectionReady: Bool

  public init(authority: Authority, migrationState: MigrationState, legacyRevision: Int64,
              manifest: ReadStateManifest? = nil, manifestCid: String? = nil, projectionReady: Bool = true) {
    self.authority = authority
    self.migrationState = migrationState
    self.legacyRevision = legacyRevision
    self.manifest = manifest
    self.manifestCid = manifestCid
    self.projectionReady = projectionReady
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    authority = try values.decode(Authority.self, forKey: .authority)
    migrationState = try values.decode(MigrationState.self, forKey: .migrationState)
    legacyRevision = try values.decode(Int64.self, forKey: .legacyRevision)
    manifest = try values.decodeIfPresent(ReadStateManifest.self, forKey: .manifest)
    manifestCid = try values.decodeIfPresent(String.self, forKey: .manifestCid)
    projectionReady = try values.decodeIfPresent(Bool.self, forKey: .projectionReady) ?? true
  }
}

