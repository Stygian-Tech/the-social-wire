export {
  createSaveUpstreamDpopProofPool,
  createUpstreamDpopProof,
  pdsXrpcMethodForGatewayRequest,
  primePdsDpopNonce,
  refreshPdsDpopNonce,
} from "latr-packages/gateway-client";

/** PDS XRPC method for Social Wire gateway routes that write through to the viewer PDS. */
export function pdsXrpcMethodForSocialWireGatewayRequest(
  gatewayMethod: string,
  gatewayPath: string
): { xrpcMethod: string; httpMethod: "GET" | "POST" } | null {
  const method = gatewayMethod.toUpperCase();
  const path = gatewayPath.split("?")[0] ?? gatewayPath;

  if (
    method === "GET" &&
    (path === "/v1/appview/bootstrap-stream" ||
      path === "/xrpc/app.thesocialwire.publication.getSidebar")
  ) {
    return {
      xrpcMethod: "com.atproto.repo.listRecords",
      httpMethod: "GET",
    };
  }

  if (
    method === "POST" &&
    path === "/xrpc/app.thesocialwire.publication.refreshSidebar"
  ) {
    return {
      xrpcMethod: "com.atproto.repo.listRecords",
      httpMethod: "GET",
    };
  }

  return null;
}
