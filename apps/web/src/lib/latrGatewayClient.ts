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
  createSaveUpstreamDpopProofPool,
  createUpstreamDpopProof,
  pdsXrpcMethodForGatewayRequest,
} from "@/lib/latrGatewayUpstreamDpop";
import { latrGatewayProxyPath } from "@/lib/latrGatewayProxyPath";
import { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";
import {
  buildLatrGatewayUserAuthHeaders,
  captureGatewayDpopNonceFromResponse,
} from "@/lib/latrGatewayUserAuth";

/** Legacy official first-party credential header (server proxy only). */
export const LATR_OFFICIAL_CLIENT_HEADER = "X-Latr-Official-Client";

export {
  LATR_API_KEY_HEADER,
  LATR_CLIENT_ID_HEADER,
  LATR_UPSTREAM_DPOP_HEADER,
};

export { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

function shouldRetryLatrGatewayDpopNonce(res: Response): boolean {
  if (res.status !== 401 && res.status !== 400) return false;
  return Boolean(res.headers.get("DPoP-Nonce")?.trim());
}

async function buildUpstreamDpopHeader(
  oauthSession: OAuthSession,
  method: string,
  gatewayPath: string
): Promise<string | undefined> {
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
  gatewayUrl: string,
  options: { dpopNonce?: string } = {}
): Promise<Record<string, string>> {
  const userAuth = await buildLatrGatewayUserAuthHeaders(
    oauthSession,
    method,
    gatewayUrl,
    options
  );
  const headers: Record<string, string> = {
    Accept: "application/json",
    ...userAuth,
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
  attempt = 0
): Promise<Response> {
  const gatewayPath = path.startsWith("/") ? path : `/${path}`;
  const gatewayUrl = `${latrGatewayBaseUrl()}${gatewayPath}`;
  const proxyUrl = latrGatewayProxyPath(gatewayPath);
  const method = init?.method ?? "GET";
  const baseHeaders = await buildLatrGatewayProxyRequestHeaders(
    oauthSession,
    method,
    gatewayPathOnly(gatewayPath),
    gatewayUrl
  );

  const res = await fetch(proxyUrl, {
    ...init,
    headers: {
      ...baseHeaders,
      ...(init?.headers ?? {}),
    },
  });

  await captureGatewayDpopNonceFromResponse(oauthSession, gatewayUrl, res);

  if (attempt === 0 && shouldRetryLatrGatewayDpopNonce(res)) {
    return latrGatewayFetch(oauthSession, path, init, attempt + 1);
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
