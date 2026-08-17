import type { OAuthSession } from "@atproto/oauth-client-browser"

type GatewayFetch = (url: string, init?: RequestInit) => Promise<Response> | Response

export function createOperationsOAuthSession(
  gatewayFetch: GatewayFetch,
  options: {
    did?: string
    algorithms?: string[]
    supportedAlgorithms?: string[]
    onDpopHeader?: (header: Record<string, unknown>) => void
    onDpopClaims?: (claims: Record<string, string | number>) => void
    onPdsRequest?: () => void
  } = {},
): OAuthSession {
  const did = options.did ?? "did:plc:operator"
  const pdsOrigin = "https://pds.example"
  const nonces = new Map<string, string>()
  let nonceIndex = 0
  let proofIndex = 0

  return {
    did,
    getTokenInfo: async () => ({ aud: pdsOrigin }),
    getTokenSet: async () => ({ access_token: "access-token", token_type: "DPoP" }),
    fetchHandler: async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith(`${pdsOrigin}/xrpc/`)) {
        options.onPdsRequest?.()
        const nonce = `pds-nonce-${++nonceIndex}`
        nonces.set(pdsOrigin, nonce)
        return Response.json(
          { records: [] },
          { headers: { "DPoP-Nonce": nonce } },
        )
      }
      return gatewayFetch(url, init)
    },
    server: {
      dpopKey: {
        bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
        algorithms: options.algorithms ?? ["ES256"],
        createJwt: async (
          header: Record<string, unknown>,
          claims: Record<string, string | number>,
        ) => {
          options.onDpopHeader?.(header)
          options.onDpopClaims?.(claims)
          proofIndex += 1
          return `pds-session-proof-${proofIndex}`
        },
      },
      dpopNonces: {
        get: async (origin: string) => nonces.get(origin),
        set: async (origin: string, nonce: string) => {
          nonces.set(origin, nonce)
        },
      },
      serverMetadata: {
        dpop_signing_alg_values_supported: options.supportedAlgorithms ?? ["ES256"],
      },
    },
  } as unknown as OAuthSession
}
