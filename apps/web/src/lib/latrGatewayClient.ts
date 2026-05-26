import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  LATR_API_KEY_HEADER,
  LATR_CLIENT_ID_HEADER,
  LATR_UPSTREAM_DPOP_HEADER,
} from "@stygian/latr-gateway-client";

import {
  createUpstreamDpopProof,
  pdsXrpcMethodForGatewayRequest,
} from "@/lib/latrGatewayUpstreamDpop";
import { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

export {
  LATR_API_KEY_HEADER,
  LATR_CLIENT_ID_HEADER,
  LATR_UPSTREAM_DPOP_HEADER,
};

export { latrGatewayBaseUrl } from "@/lib/latrGatewayUrl";

export async function latrGatewayFetch(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit
): Promise<Response> {
  const gatewayPath = path.startsWith("/") ? path : `/${path}`;
  const url = `${latrGatewayBaseUrl()}${gatewayPath}`;
  const method = init?.method ?? "GET";
  const clientId = process.env.NEXT_PUBLIC_LATR_GATEWAY_CLIENT_ID?.trim();
  const apiKey = process.env.NEXT_PUBLIC_LATR_GATEWAY_API_KEY?.trim();
  const clientHeaders: Record<string, string> = {};
  if (clientId && apiKey) {
    clientHeaders[LATR_CLIENT_ID_HEADER] = clientId;
    clientHeaders[LATR_API_KEY_HEADER] = apiKey;
  }

  const upstream = pdsXrpcMethodForGatewayRequest(method, gatewayPath);
  const upstreamHeaders: Record<string, string> = {};
  if (upstream) {
    upstreamHeaders[LATR_UPSTREAM_DPOP_HEADER] = await createUpstreamDpopProof(
      oauthSession,
      upstream.xrpcMethod,
      upstream.httpMethod
    );
  }

  return oauthSession.fetchHandler(url, {
    ...init,
    headers: {
      Accept: "application/json",
      ...clientHeaders,
      ...upstreamHeaders,
      ...(init?.headers ?? {}),
    },
  });
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
