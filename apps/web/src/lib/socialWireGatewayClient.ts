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

// PDS proof ceremonies and writes share a lane. Receipt-backed projection reads
// cannot advance the PDS nonce and do not hold this lane during server work.
const gatewayOriginQueues = new Map<string, Promise<unknown>>();
const PDS_SESSION_PREFLIGHT_PATH =
  "/xrpc/app.thesocialwire.appview.listEntries";

function enqueueForGatewayOrigin<T>(origin: string, task: () => Promise<T>, signal?: AbortSignal | null): Promise<T> {
  const prior = gatewayOriginQueues.get(origin) ?? Promise.resolve();
  const settled = prior.then(
    () => undefined,
    () => undefined
  );
  const result = settled.then(() => { signal?.throwIfAborted(); return task(); });
  gatewayOriginQueues.set(
    origin,
    result.then(
      () => undefined,
      () => undefined
    )
  );
  return waitForAbort(result, signal);
}

function waitForAbort<T>(promise: Promise<T>, signal?: AbortSignal | null): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise((resolve, reject) => {
    const aborted = () => reject(signal.reason);
    signal.addEventListener("abort", aborted, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener("abort", aborted));
  });
}

type ReceiptState = { binding: string; receipt?: string; serializedUntil?: number; pending?: Promise<Response> };
const projectionReceipts = new WeakMap<OAuthSession, Map<string, ReceiptState>>();

function isProjectionRead(path: string, init?: RequestInit): boolean {
  if ((init?.method ?? "GET").toUpperCase() !== "GET") return false;
  const route = path.split("?")[0];
  return /^\/xrpc\/app\.thesocialwire\.(appview|discovery)\.get[A-Z]/.test(route) ||
    route === "/xrpc/app.thesocialwire.sync.getPreferences" || route === "/v1/podcasts/state";
}

async function tokenBinding(oauth: OAuthSession): Promise<string> {
  const token = await (oauth as unknown as { getTokenSet(refresh: "auto"): Promise<{ access_token: string }> }).getTokenSet("auto");
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token.access_token));
  return Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, "0")).join("");
}

async function projectionRead(oauth: OAuthSession, path: string, init?: RequestInit): Promise<Response> {
  const origin = gatewayBaseUrl();
  let states = projectionReceipts.get(oauth);
  if (!states) { states = new Map(); projectionReceipts.set(oauth, states); }
  for (let attempt = 0; attempt < 2; attempt++) {
    init?.signal?.throwIfAborted();
    const binding = await tokenBinding(oauth);
    init?.signal?.throwIfAborted();
    let state = states.get(origin);
    if (!state || state.binding !== binding) {
      state = { binding }; states.set(origin, state);
    }
    if (state.serializedUntil && state.serializedUntil > Date.now()) return enqueueForGatewayOrigin(origin, () => gatewayFetchAttempt(oauth, path, init), init?.signal);
    if (!state.receipt) {
      const current = state;
      if (!current.pending) {
        const signal = AbortSignal.timeout(15_000);
        const pending = enqueueForGatewayOrigin(origin, async () => {
          const response = await gatewayFetchAttempt(oauth, pdsSessionPreflightPath(oauth.did), { signal });
          if (response.ok) {
            current.receipt = pdsSessionAttestationReceipt(response);
            current.serializedUntil = current.receipt ? undefined : Date.now() + 50_000;
          }
          return response;
        }, signal);
        current.pending = pending;
        void pending.finally(() => { if (current.pending === pending) current.pending = undefined; }).catch(() => {});
      }
      const preflight = await waitForAbort(current.pending, init?.signal);
      init?.signal?.throwIfAborted();
      if (!preflight.ok) return preflight.clone();
      // Public-JWKS authentication does not issue receipts. Preserve its existing
      // serialized path rather than sending an unbacked Prepared declaration.
      if (!current.receipt) return enqueueForGatewayOrigin(origin, () => gatewayFetchAttempt(oauth, path, init), init?.signal);
    }
    init?.signal?.throwIfAborted();
    const receipt = state.receipt;
    const response = await gatewayFetchAttempt(oauth, path, init,
      { "X-ATProto-Upstream-DPoP-Prepared": "true" }, undefined, receipt);
    if (!shouldRefreshPdsSessionAttestation(response) || attempt === 1) return response;
    // Another rejected concurrent read must not discard an already refreshed receipt.
    if (state.receipt === receipt) state.receipt = undefined;
  }
  throw new Error("Gateway receipt refresh did not produce a response");
}

export async function gatewayFetch(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit,
  prepareProofPool?: () => Promise<Readonly<Record<string, string>>>
): Promise<Response> {
  const gatewayPath = path.startsWith("/") ? path : `/${path}`;
  const run = async () => {
    const upstream = pdsXrpcMethodForSocialWireGatewayRequest(
      init?.method ?? "GET",
      gatewayPath
    );
    const prepared = Boolean(upstream || prepareProofPool);
    const ceremonyLimit = prepared ? 2 : 1;

    for (let ceremony = 0; ceremony < ceremonyLimit; ceremony += 1) {
      const upstreamHeaders: Record<string, string> = {};
      let attestationReceipt: string | undefined;

      if (prepared) {
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

        if (prepareProofPool) {
          Object.assign(upstreamHeaders, await prepareProofPool());
          upstreamHeaders["X-ATProto-Upstream-DPoP-Prepared"] = "true";
        }
        if (upstream) upstreamHeaders[LATR_UPSTREAM_DPOP_HEADER] =
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
        prepared &&
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
      if (!prepareProofPool && !pdsXrpcMethodForSocialWireGatewayRequest(init?.method ?? "GET", gatewayPath) && isProjectionRead(gatewayPath, init)) {
        return await projectionRead(oauthSession, gatewayPath, init);
      }
      return await enqueueForGatewayOrigin(gatewayBaseUrl(), run, init?.signal);
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
  init?.signal?.throwIfAborted();
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
