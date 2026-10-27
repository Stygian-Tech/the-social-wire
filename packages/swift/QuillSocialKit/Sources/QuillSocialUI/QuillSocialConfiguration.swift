#if os(iOS)
import Foundation

/// The existing app session supplies all authenticated Social requests.
public struct QuillSocialConfiguration: Sendable {
    public typealias Request = @Sendable (_ nsid: String, _ parameters: [String: String]) async throws -> Data
    public typealias Procedure = @Sendable (_ nsid: String, _ body: Data) async throws -> Data
    public typealias PublicPDSRequest = @Sendable (_ repo: String, _ nsid: String, _ parameters: [String: String]) async throws -> Data
    public typealias BlobUpload = @Sendable (_ data: Data, _ mimeType: String) async throws -> Data
    public typealias ContextualRequest = @Sendable (_ nsid: String, _ parameters: [String: String], _ proxy: String, _ labelers: [String]) async throws -> Data
    public typealias ContextualProcedure = @Sendable (_ nsid: String, _ body: Data, _ proxy: String) async throws -> Data

    public let viewerDID: String
    public let appViewRequest: Request
    public let chatRequest: Request
    public let pdsRequest: Request
    public let appViewProcedure: Procedure
    public let chatProcedure: Procedure
    public let pdsProcedure: Procedure
    public let publicPDSRequest: PublicPDSRequest
    public let uploadBlob: BlobUpload
    public let appViewRequestWithContext: ContextualRequest?
    public let appViewProcedureWithContext: ContextualProcedure?

    public init(
        viewerDID: String,
        appViewRequest: @escaping Request,
        appViewProcedure: @escaping Procedure,
        chatRequest: @escaping Request,
        chatProcedure: @escaping Procedure,
        pdsRequest: @escaping Request,
        pdsProcedure: @escaping Procedure,
        publicPDSRequest: @escaping PublicPDSRequest,
        uploadBlob: @escaping BlobUpload,
        appViewRequestWithContext: ContextualRequest? = nil,
        appViewProcedureWithContext: ContextualProcedure? = nil
    ) {
        self.viewerDID = viewerDID
        self.appViewRequest = appViewRequest
        self.chatRequest = chatRequest
        self.pdsRequest = pdsRequest
        self.appViewProcedure = appViewProcedure
        self.chatProcedure = chatProcedure
        self.pdsProcedure = pdsProcedure
        self.publicPDSRequest = publicPDSRequest
        self.uploadBlob = uploadBlob
        self.appViewRequestWithContext = appViewRequestWithContext
        self.appViewProcedureWithContext = appViewProcedureWithContext
    }
}
#endif
