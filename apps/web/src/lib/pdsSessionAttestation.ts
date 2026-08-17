import type { OAuthSession } from "@atproto/oauth-client-browser";

export const PDS_SESSION_DPOP_HEADER = "X-ATProto-Session-DPoP";
export const PDS_SESSION_DPOP_NONCE_HEADER =
  "X-ATProto-Session-DPoP-Nonce";
export const PDS_SESSION_ATTESTATION_RECEIPT_HEADER =
  "X-ATProto-Session-Attestation-Receipt";
export const PDS_SESSION_ATTESTATION_REQUIRED_HEADER =
  "X-ATProto-Session-Attestation-Required";

const PDS_SESSION_XRPC_METHOD = "com.atproto.server.getSession";

type SessionWithTokenSet = OAuthSession & {
  getTokenSet(refresh: boolean | "auto"): Promise<{ access_token: string }>;
};

export async function createPdsSessionAttestationProof(
  oauthSession: OAuthSession,
  pdsDpopNonce?: string
): Promise<string> {
  const tokenInfo = await oauthSession.getTokenInfo();
  const pdsBase = tokenInfo.aud.replace(/\/$/, "");
  const pdsOrigin = new URL(`${pdsBase}/`).origin;
  const tokenSet = await (oauthSession as SessionWithTokenSet).getTokenSet(
    "auto"
  );
  let cachedNonce: string | undefined;
  try {
    cachedNonce = await oauthSession.server.dpopNonces.get(pdsOrigin);
  } catch {
    /* A cold or unavailable cache is handled by Gateway's dedicated challenge. */
  }
  const nonce = pdsDpopNonce ?? cachedNonce;
  const key = oauthSession.server.dpopKey;
  const jwk = key.bareJwk;
  if (!jwk) throw new Error("OAuth session DPoP key is unavailable");

  const supported =
    oauthSession.server.serverMetadata.dpop_signing_alg_values_supported;
  const alg = supported?.length
    ? supported.find((candidate) => key.algorithms.includes(candidate))
    : key.algorithms[0];
  if (!alg) throw new Error("OAuth session DPoP key has no supported algorithm");

  return key.createJwt(
    { alg, typ: "dpop+jwt", jwk },
    {
      iat: Math.floor(Date.now() / 1000),
      jti: crypto.randomUUID(),
      htm: "GET",
      htu: `${pdsBase}/xrpc/${PDS_SESSION_XRPC_METHOD}`,
      ath: await sha256Base64Url(tokenSet.access_token),
      ...(nonce ? { nonce } : {}),
    }
  );
}

export function shouldRetryPdsSessionAttestation(
  response: Response
): boolean {
  return (
    (response.status === 400 || response.status === 401) &&
    Boolean(readPdsSessionAttestationNonce(response))
  );
}

export function pdsSessionAttestationReceipt(
  response: Response
): string | undefined {
  return (
    response.headers.get(PDS_SESSION_ATTESTATION_RECEIPT_HEADER)?.trim() ||
    undefined
  );
}

export function shouldRefreshPdsSessionAttestation(
  response: Response
): boolean {
  return (
    response.status === 428 &&
    response.headers
      .get(PDS_SESSION_ATTESTATION_REQUIRED_HEADER)
      ?.trim()
      .toLowerCase() === "true"
  );
}

export async function capturePdsSessionAttestationNonce(
  oauthSession: OAuthSession,
  response: Response
): Promise<string | undefined> {
  const nonce = readPdsSessionAttestationNonce(response);
  if (!nonce) return undefined;

  try {
    const tokenInfo = await oauthSession.getTokenInfo();
    const pdsOrigin = new URL(tokenInfo.aud).origin;
    await oauthSession.server.dpopNonces.set(pdsOrigin, nonce);
  } catch {
    // The explicit nonce still drives this retry even if the cache is unavailable.
  }
  return nonce;
}

function readPdsSessionAttestationNonce(
  response: Response
): string | undefined {
  return response.headers.get(PDS_SESSION_DPOP_NONCE_HEADER)?.trim() || undefined;
}

async function sha256Base64Url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input)
  );
  let binary = "";
  for (const byte of new Uint8Array(digest)) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}
