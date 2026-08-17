import type { OAuthSession } from "@atproto/oauth-client-browser";
import { LATR_UPSTREAM_DPOP_HEADER } from "latr-packages/gateway-client";

import {
  createUpstreamDpopProof,
  pdsXrpcMethodForSocialWireGatewayRequest,
} from "@/lib/latrGatewayUpstreamDpop";
import {
  buildLatrGatewayUserAuthHeaders,
  captureGatewayDpopNonceFromResponse,
} from "@/lib/latrGatewayUserAuth";
import {
  invalidateOAuthSession,
  isTerminalOAuthSessionError,
} from "@/lib/auth";

export function gatewayBaseUrl(): string {
  return (
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL ?? "https://api.thesocialwire.app"
  ).replace(/\/$/, "");
}

type OAuthSessionWithManualDpop = OAuthSession & {
  getTokenSet?: unknown;
  server?: {
    dpopKey?: unknown;
  };
};

function canManuallySignGatewayRequest(
  oauthSession: OAuthSession
): oauthSession is OAuthSession & {
  getTokenSet: NonNullable<OAuthSessionWithManualDpop["getTokenSet"]>;
  server: { dpopKey: NonNullable<OAuthSessionWithManualDpop["server"]>["dpopKey"] };
} {
  const candidate = oauthSession as OAuthSessionWithManualDpop;
  return (
    typeof candidate.getTokenSet === "function" &&
    typeof candidate.server?.dpopKey === "object" &&
    candidate.server.dpopKey !== null
  );
}

function shouldRetryGatewayDpopNonce(res: Response): boolean {
  if (res.status !== 401 && res.status !== 400) return false;
  return Boolean(res.headers.get("DPoP-Nonce")?.trim());
}

/**
 * Manually-signed requests read the cached DPoP nonce, mint a proof, and only refresh the
 * cache once the response comes back. Concurrent callers (e.g. bulk mark-read/unread, which
 * fire one write per entry) all read the same stale nonce before any of them return, so the
 * gateway accepts one and rejects the rest with 400. Serializing dispatch per gateway origin
 * makes each request observe the previous one's refreshed nonce instead of racing it.
 */
const gatewayOriginQueues = new Map<string, Promise<unknown>>();

function enqueueForGatewayOrigin<T>(origin: string, task: () => Promise<T>): Promise<T> {
  const prior = gatewayOriginQueues.get(origin) ?? Promise.resolve();
  const settled = prior.then(
    () => undefined,
    () => undefined
  );
  const result = settled.then(task);
  gatewayOriginQueues.set(
    origin,
    result.then(
      () => undefined,
      () => undefined
    )
  );
  return result;
}

export async function gatewayFetch(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit,
  attempt = 0,
  gatewayDpopNonce?: string
): Promise<Response> {
  const run = () =>
    gatewayFetchAttempt(oauthSession, path, init, attempt, gatewayDpopNonce);
  try {
    if (attempt === 0 && canManuallySignGatewayRequest(oauthSession)) {
      return await enqueueForGatewayOrigin(gatewayBaseUrl(), run);
    }
    return await run();
  } catch (error) {
    // A Gateway 401 can be caused by edge policy or DPoP verification. Only an
    // OAuth-client refresh/revocation failure proves the local session is unusable.
    if (isTerminalOAuthSessionError(error)) {
      invalidateOAuthSession(oauthSession.did, error);
    }
    throw error;
  }
}

async function gatewayFetchAttempt(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit,
  attempt = 0,
  gatewayDpopNonce?: string
): Promise<Response> {
  const gatewayPath = path.startsWith("/") ? path : `/${path}`;
  const url = `${gatewayBaseUrl()}${gatewayPath}`;
  const method = init?.method ?? "GET";
  const upstreamHeaders: Record<string, string> = {};
  const upstream = pdsXrpcMethodForSocialWireGatewayRequest(method, gatewayPath);
  if (upstream) {
    upstreamHeaders[LATR_UPSTREAM_DPOP_HEADER] = await createUpstreamDpopProof(
      oauthSession,
      upstream.xrpcMethod,
      upstream.httpMethod
    );
  }

  if (!canManuallySignGatewayRequest(oauthSession)) {
    return oauthSession.fetchHandler(url, {
      ...init,
      headers: {
        Accept: "application/json",
        ...upstreamHeaders,
        ...(init?.headers ?? {}),
      },
    });
  }

  const userAuthHeaders = await buildLatrGatewayUserAuthHeaders(
    oauthSession,
    method,
    url,
    gatewayDpopNonce ? { dpopNonce: gatewayDpopNonce } : {}
  );
  const headers = new Headers(init?.headers);
  if (!headers.has("Accept")) {
    headers.set("Accept", "application/json");
  }
  for (const [name, value] of Object.entries(upstreamHeaders)) {
    headers.set(name, value);
  }
  for (const [name, value] of Object.entries(userAuthHeaders)) {
    headers.set(name, value);
  }

  const res = await fetch(url, {
    ...init,
    headers,
  });

  await captureGatewayDpopNonceFromResponse(oauthSession, url, res);

  if (attempt === 0 && shouldRetryGatewayDpopNonce(res)) {
    const retryNonce =
      res.headers.get("DPoP-Nonce")?.trim() ??
      res.headers.get("dpop-nonce")?.trim();
    return gatewayFetchAttempt(
      oauthSession,
      path,
      init,
      attempt + 1,
      retryNonce
    );
  }

  return res;
}
