import Foundation
import GatewayCore
import Hummingbird
import ReadStateCore
import ThinAppViewCore

struct PDSReadStateRoutes {
  let service: PDSReadStateService

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/xrpc/app.thesocialwire.appview.getReadStateStatus") { _, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      return try await self.respond(context: context) {
        try await service.store.pdsReadStateStatus(viewerDid: auth.did)
      }
    }
    group.post("/xrpc/app.thesocialwire.appview.exportReadState") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PDSReadStateExportRequest.self, context: context)
      return try await self.respond(context: context) {
        try await service.store.exportPDSReadStatePage(viewerDid: auth.did, cursor: body.cursor,
          expectedLegacyRevision: body.expectedLegacyRevision, limit: min(max(body.limit ?? 100, 1), 500))
      }
    }
    group.post("/xrpc/app.thesocialwire.appview.prepareReadState") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PDSReadStatePrepareRequest.self, context: context)
      return try await self.respond(context: context) { try await service.prepare(auth: auth, request: body) }
    }
    group.post("/xrpc/app.thesocialwire.appview.confirmReadState") { request, context async throws -> Response in
      guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
      let body = try await request.decode(as: PDSReadStateConfirmRequest.self, context: context)
      return try await self.respond(context: context) { try await service.confirm(viewerDid: auth.did, request: body) }
    }
  }

  private func respond<T: Encodable>(context: GatewayRequestContext,
    operation: () async throws -> T) async throws -> Response {
    do {
      let body = try JSONEncoder().encode(try await operation())
      return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
        body: .init(byteBuffer: .init(data: body)))
    } catch let error as PDSReadStateStorageError {
      throw HTTPError(error == .invalidCursor ? .badRequest : .conflict,
        message: "Read-state migration could not be confirmed: \(error)")
    } catch is ReadStateError {
      throw HTTPError(.conflict, message: "Read-state generation is invalid or incomplete")
    }
  }
}
