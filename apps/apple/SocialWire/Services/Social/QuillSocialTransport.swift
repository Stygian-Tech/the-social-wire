#if os(iOS)
import Foundation
import QuillSocialUI

/// Adapts Quill's lexicon sources to the existing Social Wire OAuth session.
@MainActor
enum QuillSocialTransport {
    static func configuration(xrpc: XRPCClient, viewerDID: String) -> QuillSocialConfiguration {
        QuillSocialConfiguration(
            viewerDID: viewerDID,
            appViewRequest: { method, query in
                try await xrpc.socialServiceGetData(method: method, service: "did:web:api.bsky.app#bsky_appview",
                                                    query: query, expectedViewer: viewerDID)
            },
            appViewProcedure: { method, body in
                try await xrpc.socialServicePostData(method: method, service: "did:web:api.bsky.app#bsky_appview",
                                                     body: body, expectedViewer: viewerDID)
            },
            chatRequest: { method, query in
                try await xrpc.socialServiceGetData(method: method, service: "did:web:api.bsky.chat#bsky_chat",
                                                    query: query, expectedViewer: viewerDID)
            },
            chatProcedure: { method, body in
                try await xrpc.socialServicePostData(method: method, service: "did:web:api.bsky.chat#bsky_chat",
                                                     body: body, expectedViewer: viewerDID)
            },
            pdsRequest: { method, query in
                try await xrpc.socialPDSGetData(method: method, query: query, expectedViewer: viewerDID)
            },
            pdsProcedure: { method, body in
                try await xrpc.socialPDSPostData(method: method, body: body, expectedViewer: viewerDID)
            },
            publicPDSRequest: { repo, method, query in
                try await xrpc.socialPublicPDSGetData(repo: repo, method: method, query: query, expectedViewer: viewerDID)
            },
            uploadBlob: { data, mimeType in
                try await xrpc.socialUploadBlobData(data: data, mimeType: mimeType, expectedViewer: viewerDID)
            },
            appViewRequestWithContext: { method, query, proxy, labelers in
                try await xrpc.socialServiceGetData(method: method, service: proxy, query: query,
                                                    labelers: labelers, expectedViewer: viewerDID)
            },
            appViewProcedureWithContext: { method, body, proxy in
                try await xrpc.socialServicePostData(method: method, service: proxy, body: body, expectedViewer: viewerDID)
            }
        )
    }
}
#endif
