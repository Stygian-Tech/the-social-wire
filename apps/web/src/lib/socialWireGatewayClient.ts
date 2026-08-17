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
import {
  capturePdsSessionAttestationNonce,
  createPdsSessionAttestationProof,
  pdsSessionAttestationReceipt,
  PDS_SESSION_ATTESTATION_RECEIPT_HEADER,
  PDS_SESSION_DPOP_HEADER,
  shouldRefreshPdsSessionAttestation,
  shouldRetryPdsSessionAttestation,
} from "@/lib/pdsSessionAttestation";

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
const PDS_SESSION_PREFLIGHT_PATH =
  "/xrpc/app.thesocialwire.appview.listEntries";

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
  init?: RequestInit
): Promise<Response> {
  const run = async () => {
    const gatewayPath = path.startsWith("/") ? path : `/${path}`;
    const upstream = pdsXrpcMethodForSocialWireGatewayRequest(
      init?.method ?? "GET",
      gatewayPath
    );
    const ceremonyLimit = upstream ? 2 : 1;

    for (let ceremony = 0; ceremony < ceremonyLimit; ceremony += 1) {
      const upstreamHeaders: Record<string, string> = {};
      let attestationReceipt: string | undefined;

      if (upstream) {
        // Obtain a portable, short-lived attestation receipt before advancing
        // the PDS nonce chain for the route-specific proof.
        const preflightProof = await createPdsSessionAttestationProof(oauthSession);
        const preflight = await gatewayFetchAttempt(
          oauthSession,
          pdsSessionPreflightPath(oauthSession.did),
          undefined,
          {},
          preflightProof
        );
        if (!preflight.ok) return preflight;
        attestationReceipt = pdsSessionAttestationReceipt(preflight);

        upstreamHeaders[LATR_UPSTREAM_DPOP_HEADER] =
          await createUpstreamDpopProof(
            oauthSession,
            upstream.xrpcMethod,
            upstream.httpMethod
          );
      }

      // Route proof pools advance the PDS nonce chain. Mint the session proof last
      // so the attestation carries the freshest nonce when Gateway validates it.
      const pdsSessionProof = await createPdsSessionAttestationProof(oauthSession);
      const response = await gatewayFetchAttempt(
        oauthSession,
        path,
        init,
        upstreamHeaders,
        pdsSessionProof,
        attestationReceipt
      );
      if (
        upstream &&
        ceremony + 1 < ceremonyLimit &&
        shouldRefreshPdsSessionAttestation(response)
      ) {
        continue;
      }
      return response;
    }

    throw new Error("Gateway attestation ceremony did not produce a response");
  };
  try {
    if (canManuallySignGatewayRequest(oauthSession)) {
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
  upstreamHeaders: Readonly<Record<string, string>> = {},
  pdsSessionProof?: string,
  attestationReceipt?: string,
  attempts: { gateway: number; pdsSession: number } = {
    gateway: 0,
    pdsSession: 0,
  },
  gatewayDpopNonce?: string
): Promise<Response> {
  const gatewayPath = path.startsWith("/") ? path : `/${path}`;
  const url = `${gatewayBaseUrl()}${gatewayPath}`;
  const method = init?.method ?? "GET";
  const sessionProof =
    pdsSessionProof ?? (await createPdsSessionAttestationProof(oauthSession));

  if (!canManuallySignGatewayRequest(oauthSession)) {
    const headers = new Headers(init?.headers);
    if (!headers.has("Accept")) headers.set("Accept", "application/json");
    for (const [name, value] of Object.entries(upstreamHeaders)) {
      headers.set(name, value);
    }
    if (attestationReceipt) {
      headers.set(PDS_SESSION_ATTESTATION_RECEIPT_HEADER, attestationReceipt);
    }
    headers.set(PDS_SESSION_DPOP_HEADER, sessionProof);
    const response = await oauthSession.fetchHandler(url, {
      ...init,
      headers,
    });
    return retryPdsSessionAttestationIfNeeded(
      oauthSession,
      path,
      init,
      upstreamHeaders,
      response,
      attestationReceipt,
      attempts,
      gatewayDpopNonce
    );
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
  if (attestationReceipt) {
    headers.set(PDS_SESSION_ATTESTATION_RECEIPT_HEADER, attestationReceipt);
  }
  for (const [name, value] of Object.entries(userAuthHeaders)) {
    headers.set(name, value);
  }
  headers.set(PDS_SESSION_DPOP_HEADER, sessionProof);

  const res = await fetch(url, {
    ...init,
    headers,
  });

  await captureGatewayDpopNonceFromResponse(oauthSession, url, res);
  const pdsSessionNonce = await capturePdsSessionAttestationNonce(
    oauthSession,
    res
  );

  if (attempts.pdsSession === 0 && shouldRetryPdsSessionAttestation(res)) {
    const retryProof = await createPdsSessionAttestationProof(
      oauthSession,
      pdsSessionNonce
    );
    return gatewayFetchAttempt(
      oauthSession,
      path,
      init,
      upstreamHeaders,
      retryProof,
      attestationReceipt,
      { ...attempts, pdsSession: 1 },
      gatewayDpopNonce
    );
  }

  if (attempts.gateway === 0 && shouldRetryGatewayDpopNonce(res)) {
    const retryNonce =
      res.headers.get("DPoP-Nonce")?.trim() ??
      res.headers.get("dpop-nonce")?.trim();
    const retryProof = await createPdsSessionAttestationProof(oauthSession);
    return gatewayFetchAttempt(
      oauthSession,
      path,
      init,
      upstreamHeaders,
      retryProof,
      attestationReceipt,
      { ...attempts, gateway: 1 },
      retryNonce
    );
  }

  return res;
}

function pdsSessionPreflightPath(did: string): string {
  const query = new URLSearchParams({ authorDid: did, limit: "1" });
  return `${PDS_SESSION_PREFLIGHT_PATH}?${query}`;
}

async function retryPdsSessionAttestationIfNeeded(
  oauthSession: OAuthSession,
  path: string,
  init: RequestInit | undefined,
  upstreamHeaders: Readonly<Record<string, string>>,
  response: Response,
  attestationReceipt: string | undefined,
  attempts: { gateway: number; pdsSession: number },
  gatewayDpopNonce?: string
): Promise<Response> {
  const pdsSessionNonce = await capturePdsSessionAttestationNonce(
    oauthSession,
    response
  );
  if (
    attempts.pdsSession > 0 ||
    !shouldRetryPdsSessionAttestation(response)
  ) {
    return response;
  }

  const retryProof = await createPdsSessionAttestationProof(
    oauthSession,
    pdsSessionNonce
  );
  return gatewayFetchAttempt(
    oauthSession,
    path,
    init,
    upstreamHeaders,
    retryProof,
    attestationReceipt,
    { ...attempts, pdsSession: 1 },
    gatewayDpopNonce
  );
}
