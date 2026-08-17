import type { OAuthSession } from "@atproto/oauth-client-browser"

export const pdsSessionDpopHeader = "X-ATProto-Session-DPoP"
export const pdsSessionDpopNonceHeader = "X-ATProto-Session-DPoP-Nonce"

type SessionWithTokenSet = OAuthSession & {
  getTokenSet(refresh: boolean | "auto"): Promise<{ access_token: string }>
}

export async function createPdsSessionAttestationProof(
  session: OAuthSession,
  pdsDpopNonce?: string,
) {
  const tokenInfo = await session.getTokenInfo()
  const pdsBase = tokenInfo.aud.replace(/\/$/, "")
  const pdsOrigin = new URL(`${pdsBase}/`).origin
  const tokenSet = await (session as SessionWithTokenSet).getTokenSet("auto")
  let cachedNonce: string | undefined
  try {
    cachedNonce = await session.server.dpopNonces.get(pdsOrigin)
  } catch {
    /* A cold or unavailable cache is handled by Gateway's dedicated challenge. */
  }
  const nonce = pdsDpopNonce ?? cachedNonce
  const key = session.server.dpopKey
  const jwk = key.bareJwk
  if (!jwk) throw new Error("OAuth session DPoP key is unavailable")

  const supported = session.server.serverMetadata.dpop_signing_alg_values_supported
  const alg = supported?.length
    ? supported.find((candidate) => key.algorithms.includes(candidate))
    : key.algorithms[0]
  if (!alg) throw new Error("OAuth session DPoP key has no supported algorithm")

  return key.createJwt(
    { alg, typ: "dpop+jwt", jwk },
    {
      iat: Math.floor(Date.now() / 1000),
      jti: crypto.randomUUID(),
      htm: "GET",
      htu: `${pdsBase}/xrpc/com.atproto.server.getSession`,
      ath: await sha256Base64Url(tokenSet.access_token),
      ...(nonce ? { nonce } : {}),
    },
  )
}

export function shouldRetryPdsSessionAttestation(response: Response) {
  return (
    (response.status === 400 || response.status === 401) &&
    Boolean(readPdsSessionAttestationNonce(response))
  )
}

export async function capturePdsSessionAttestationNonce(
  session: OAuthSession,
  response: Response,
) {
  const nonce = readPdsSessionAttestationNonce(response)
  if (!nonce) return undefined

  try {
    const tokenInfo = await session.getTokenInfo()
    await session.server.dpopNonces.set(new URL(tokenInfo.aud).origin, nonce)
  } catch {
    // The explicit nonce still drives this retry even if the cache is unavailable.
  }
  return nonce
}

function readPdsSessionAttestationNonce(response: Response) {
  return response.headers.get(pdsSessionDpopNonceHeader)?.trim() || undefined
}

async function sha256Base64Url(input: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input))
  let binary = ""
  for (const byte of new Uint8Array(digest)) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}
