import Foundation
import ReadStateCore

/// Implementations fence every legacy mutation against activation and page exports.
public protocol PDSReadStateStoring: Sendable {
  func pdsReadStateStatus(viewerDid: String) async throws -> PDSReadStateStatus

  func exportPDSReadStatePage(
    viewerDid: String, cursor: String?, expectedLegacyRevision: Int64?, limit: Int
  ) async throws -> PDSReadStateExportPage

  /// Projection must come from the viewer's resolved PDS, not a client-supplied payload.
  /// Initial activation proves the entire legacy baseline before changing authority.
  func activatePDSReadState(
    viewerDid: String, manifest: ReadStateManifest, manifestCid: String,
    projection: ReadStateProjection, expectedLegacyRevision: Int64?
  ) async throws -> PDSReadStateStatus

  func previewPDSReadStateBoundaries(viewerDid: String, boundaries: [ReadStateBoundary],
    subjectUris: [String]) async throws -> [String]

  /// Freezes existing mark-all boundaries without changing the viewer's state.
  func preparePDSReadStateBoundaries(
    viewerDid: String, scopes: [PublicationUnreadScope], at: Date
  ) async throws -> [ReadStateBoundary]
}
