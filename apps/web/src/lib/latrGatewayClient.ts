import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  LATR_UPSTREAM_DPOP_HEADER,
} from "latr-packages/gateway-client";

import {
  createUpstreamDpopProof,
  pdsXrpcMethodForGatewayRequest,
} from "@/lib/latrGatewayUpstreamDpop";
import { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

/** Official first-party credential for latr-gateway (`LATR_GATEWAY_OFFICIAL_CLIENT_CREDENTIALS`). */
export const LATR_OFFICIAL_CLIENT_HEADER = "X-Latr-Official-Client";

export { LATR_UPSTREAM_DPOP_HEADER };

export { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

function shouldRetryLatrGatewayDpopNonce(res: Response): boolean {
  if (res.status !== 401 && res.status !== 400) return false;
  return Boolean(res.headers.get("DPoP-Nonce")?.trim());
}

async function buildLatrGatewayRequestHeaders(
  oauthSession: OAuthSession,
  method: string,
  gatewayPath: string
): Promise<Record<string, string>> {
  const clientCredential = process.env.NEXT_PUBLIC_LATR_GATEWAY_CLIENT_CREDENTIAL?.trim();
  const headers: Record<string, string> = {
    Accept: "application/json",
  };
  if (clientCredential) {
    headers[LATR_OFFICIAL_CLIENT_HEADER] = clientCredential;
  }

  const upstream = pdsXrpcMethodForGatewayRequest(method, gatewayPath);
  if (upstream) {
    headers[LATR_UPSTREAM_DPOP_HEADER] = await createUpstreamDpopProof(
      oauthSession,
      upstream.xrpcMethod,
      upstream.httpMethod
    );
  }
  return headers;
}

export async function latrGatewayFetch(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit,
  attempt = 0
): Promise<Response> {
  const gatewayPath = path.startsWith("/") ? path : `/${path}`;
  const url = `${latrGatewayBaseUrl()}${gatewayPath}`;
  const method = init?.method ?? "GET";
  const baseHeaders = await buildLatrGatewayRequestHeaders(
    oauthSession,
    method,
    gatewayPath
  );

  const res = await oauthSession.fetchHandler(url, {
    ...init,
    headers: {
      ...baseHeaders,
      ...(init?.headers ?? {}),
    },
  });

  if (attempt === 0 && shouldRetryLatrGatewayDpopNonce(res)) {
    return latrGatewayFetch(oauthSession, path, init, attempt + 1);
  }

  return res;
}

async function readGatewayError(res: Response): Promise<string> {
  try {
    const body = (await res.json()) as { message?: string; error?: string };
    return body.message ?? body.error ?? `Gateway error (${res.status})`;
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
