import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  LATR_API_KEY_HEADER,
  LATR_CLIENT_ID_HEADER,
  LATR_UPSTREAM_DPOP_HEADER,
} from "latr-packages/gateway-client";

import {
  isLatrGatewayAuthRejected,
  isLatrGatewayInvalidClientCredentialResponse,
  markLatrGatewayAuthRejected,
} from "@/lib/latrGatewayCredentials";
import { latrGatewayErrorMessage } from "@/lib/latrGatewayErrors";
import {
  bookmarkUpstreamProofPlanForGatewayRequest,
  createBookmarkUpstreamDpopProofPool,
  createSaveUpstreamDpopProofPool,
  createUpstreamDpopProof,
  createUpstreamDpopProofPool,
  pdsXrpcMethodForGatewayRequest,
} from "latr-packages/gateway-client";
import { latrGatewayProxyPath } from "@/lib/latrGatewayProxyPath";
import {
  buildLatrGatewayUserAuthHeaders,
  captureGatewayDpopNonceFromResponse,
  latrGatewayProxyAuthUrl,
} from "@/lib/latrGatewayUserAuth";
import { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

/** Legacy official first-party credential header (server proxy only). */
export const LATR_OFFICIAL_CLIENT_HEADER = "X-Latr-Official-Client";
export const LATR_GATEWAY_DPOP_HEADER = "X-Latr-Gateway-DPoP";

export {
  LATR_API_KEY_HEADER,
  LATR_CLIENT_ID_HEADER,
  LATR_UPSTREAM_DPOP_HEADER,
};

export { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

const PDS_SESSION_ATTESTATION_PATHS = new Set([
  "/v1/latr/discover/at-uri",
  "/v1/latr/og-preview",
]);

function shouldRetryLatrGatewayDpopNonce(res: Response): boolean {
  if (res.status !== 401 && res.status !== 400) return false;
  return Boolean(res.headers.get("DPoP-Nonce")?.trim());
}

async function buildUpstreamDpopHeader(
  oauthSession: OAuthSession,
  method: string,
  gatewayPath: string
): Promise<string | undefined> {
  const bookmarkPlan = bookmarkUpstreamProofPlanForGatewayRequest(
    method,
    gatewayPath
  );
  if (bookmarkPlan?.transport === "header") {
    return createBookmarkUpstreamDpopProofPool(
      oauthSession,
      method,
      gatewayPath
    );
  }
  if (bookmarkPlan?.transport === "body") return undefined;

  if (method === "GET" && PDS_SESSION_ATTESTATION_PATHS.has(gatewayPath)) {
    return createUpstreamDpopProof(
      oauthSession,
      "com.atproto.server.getSession",
      "GET"
    );
  }

  if (method === "GET" && gatewayPath === "/v1/latr/saves") {
    return createUpstreamDpopProofPool(
      oauthSession,
      [
        {
          xrpcMethod: "com.atproto.repo.listRecords",
          httpMethod: "GET",
          count: 8,
        },
      ]
    );
  }

  if (method === "POST" && gatewayPath === "/v1/latr/saves") {
    return createSaveUpstreamDpopProofPool(oauthSession);
  }

  const upstream = pdsXrpcMethodForGatewayRequest(method, gatewayPath);
  if (!upstream) return undefined;

  return createUpstreamDpopProof(
    oauthSession,
    upstream.xrpcMethod,
    upstream.httpMethod
  );
}

async function buildLatrGatewayProxyRequestHeaders(
  oauthSession: OAuthSession,
  method: string,
  gatewayPath: string,
  proxyAuthUrl: string,
  options: { dpopNonce?: string } = {}
): Promise<Record<string, string>> {
  const proxyUserAuth = await buildLatrGatewayUserAuthHeaders(
    oauthSession,
    method,
    proxyAuthUrl,
    { useCachedNonce: false }
  );
  const latrGatewayUserAuth = await buildLatrGatewayUserAuthHeaders(
    oauthSession,
    method,
    `${latrGatewayBaseUrl()}${gatewayPath}`,
    options
  );
  const headers: Record<string, string> = {
    Accept: "application/json",
    Authorization: proxyUserAuth.Authorization,
    DPoP: proxyUserAuth.DPoP,
    [LATR_GATEWAY_DPOP_HEADER]: latrGatewayUserAuth.DPoP,
  };

  const upstreamProof = await buildUpstreamDpopHeader(
    oauthSession,
    method,
    gatewayPath
  );
  if (upstreamProof) {
    headers[LATR_UPSTREAM_DPOP_HEADER] = upstreamProof;
  }
  return headers;
}

function gatewayPathOnly(path: string): string {
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return normalized.split("?", 1)[0] ?? normalized;
}

export async function latrGatewayFetch(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit,
  attempt = 0,
  gatewayDpopNonce?: string
): Promise<Response> {
  const gatewayPath = path.startsWith("/") ? path : `/${path}`;
  const proxyUrl = latrGatewayProxyPath(gatewayPath);
  const proxyAuthUrl = latrGatewayProxyAuthUrl(proxyUrl);
  const method = init?.method ?? "GET";
  const baseHeaders = await buildLatrGatewayProxyRequestHeaders(
    oauthSession,
    method,
    gatewayPathOnly(gatewayPath),
    proxyAuthUrl,
    gatewayDpopNonce ? { dpopNonce: gatewayDpopNonce } : {}
  );

  const res = await fetch(proxyUrl, {
    ...init,
    headers: {
      ...baseHeaders,
      ...(init?.headers ?? {}),
    },
  });

  await captureGatewayDpopNonceFromResponse(
    oauthSession,
    `${latrGatewayBaseUrl()}${gatewayPathOnly(gatewayPath)}`,
    res
  );

  if (attempt === 0 && shouldRetryLatrGatewayDpopNonce(res)) {
    const retryNonce =
      res.headers.get("DPoP-Nonce")?.trim() ??
      res.headers.get("dpop-nonce")?.trim();
    return latrGatewayFetch(
      oauthSession,
      path,
      init,
      attempt + 1,
      retryNonce
    );
  }

  await noteInvalidClientCredential(res);
  return res;
}

async function noteInvalidClientCredential(res: Response): Promise<void> {
  if (isLatrGatewayAuthRejected()) return;
  try {
    const body = (await res.clone().json()) as { message?: string; error?: string };
    if (isLatrGatewayInvalidClientCredentialResponse(res.status, body)) {
      markLatrGatewayAuthRejected();
    }
  } catch {
    /* ignore parse failures */
  }
}

async function readGatewayError(res: Response): Promise<string> {
  try {
    const body = (await res.json()) as { message?: string; error?: string };
    return latrGatewayErrorMessage(res.status, body);
  } catch {
    return `Gateway error (${res.status})`;
  }
}

export async function latrGatewayJson<T>(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit
): Promise<T> {
  const res = await latrGatewayFetch(oauthSession, path, init);
  if (!res.ok) {
    throw new Error(await readGatewayError(res));
  }
  return (await res.json()) as T;
}
