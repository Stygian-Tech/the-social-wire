import { afterEach, expect, test } from "bun:test"
import {
  OAuthResponseError,
  TokenRefreshError,
} from "@atproto/oauth-client-browser"
import {
  authFetch,
  isTerminalOAuthSessionError,
  onOAuthSessionInvalidated,
} from "@/lib/auth"
import { createOperationsOAuthSession } from "@/__tests__/oauth-session"
import {
  createPdsSessionAttestationProof,
  pdsSessionDpopHeader,
  pdsSessionDpopNonceHeader,
} from "@/lib/pds-session-attestation"

const storedDidKey = "@@atproto/oauth-client-browser(sub)"

afterEach(() => {
  window.localStorage.clear()
})

test("recognizes terminal token refresh responses", () => {
  const responseError = new OAuthResponseError(
    new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }),
    { error: "invalid_grant" },
  )

  expect(isTerminalOAuthSessionError(responseError)).toBe(true)
  expect(isTerminalOAuthSessionError(new TypeError("Network unavailable"))).toBe(false)
})

test("fails closed when advertised DPoP algorithms do not match the session key", async () => {
  const session = createOperationsOAuthSession(async () => Response.json({ ok: true }), {
    algorithms: ["ES256"],
    supportedAlgorithms: ["PS256"],
  })

  await expect(createPdsSessionAttestationProof(session)).rejects.toThrow(
    "OAuth session DPoP key has no supported algorithm",
  )
})

test("uses the advertised DPoP algorithm when it matches the session key", async () => {
  const headers: Array<Record<string, unknown>> = []
  const session = createOperationsOAuthSession(async () => Response.json({ ok: true }), {
    algorithms: ["ES256"],
    supportedAlgorithms: ["PS256", "ES256"],
    onDpopHeader: (header) => headers.push(header),
  })

  await createPdsSessionAttestationProof(session)

  expect(headers).toHaveLength(1)
  expect(headers[0]?.alg).toBe("ES256")
})

test("attests every protected request with one PDS getSession-bound proof", async () => {
  const claims: Array<Record<string, string | number>> = []
  let pdsRequests = 0
  let requestHeaders = new Headers()
  const session = createOperationsOAuthSession(
    async (_url, init) => {
      requestHeaders = new Headers(init?.headers)
      return Response.json({ ok: true })
    },
    {
      onDpopClaims: (value) => claims.push(value),
      onPdsRequest: () => {
        pdsRequests += 1
      },
    },
  )

  const response = await authFetch(
    session,
    "https://api.testing.thesocialwire.app/v1/operations/overview",
  )

  expect(response.status).toBe(200)
  expect(requestHeaders.get(pdsSessionDpopHeader)).toBe("pds-session-proof-1")
  expect(requestHeaders.get(pdsSessionDpopHeader)).not.toContain(",")
  expect(claims).toHaveLength(1)
  expect(claims[0]).toMatchObject({
    htm: "GET",
    htu: "https://pds.example/xrpc/com.atproto.server.getSession",
  })
  expect(claims[0]).not.toHaveProperty("nonce")
  expect(claims[0]?.ath).toBeTruthy()
  expect(pdsRequests).toBe(0)
})

test("retries only the session proof for its dedicated PDS nonce challenge", async () => {
  const claims: Array<Record<string, string | number>> = []
  const sessionProofs: string[] = []
  const routeProofs: string[] = []
  let pdsRequests = 0
  let calls = 0
  const session = createOperationsOAuthSession(
    async (_url, init) => {
      calls += 1
      const headers = new Headers(init?.headers)
      sessionProofs.push(headers.get(pdsSessionDpopHeader) ?? "")
      routeProofs.push(headers.get("X-ATProto-Upstream-DPoP") ?? "")
      if (calls === 1) {
        return Response.json(
          { error: "use_pds_session_dpop_nonce" },
          {
            status: 401,
            headers: {
              [pdsSessionDpopNonceHeader]: "challenge-pds-nonce",
              "DPoP-Nonce": "gateway-nonce-must-remain-isolated",
            },
          },
        )
      }
      return Response.json(
        { ok: true },
        { headers: { [pdsSessionDpopNonceHeader]: "rotated-pds-nonce" } },
      )
    },
    {
      onDpopClaims: (value) => claims.push(value),
      onPdsRequest: () => {
        pdsRequests += 1
      },
    },
  )

  const response = await authFetch(
    session,
    "https://api.testing.thesocialwire.app/v1/operations/overview",
    { headers: { "X-ATProto-Upstream-DPoP": "route-proof" } },
  )

  expect(response.status).toBe(200)
  expect(sessionProofs).toEqual(["pds-session-proof-1", "pds-session-proof-2"])
  expect(routeProofs).toEqual(["route-proof", "route-proof"])
  expect(claims[0]).not.toHaveProperty("nonce")
  expect(claims[1]?.nonce).toBe("challenge-pds-nonce")
  expect(new Set(claims.map((value) => value.jti)).size).toBe(2)
  expect(pdsRequests).toBe(0)
  expect(await session.server.dpopNonces.get("https://pds.example")).toBe(
    "rotated-pds-nonce",
  )
})

test("returns a raw gateway 401 without invalidating the local session", async () => {
  const invalidations: string[] = []
  const unsubscribe = onOAuthSessionInvalidated((did) => invalidations.push(did))
  const session = createOperationsOAuthSession(async () =>
    Response.json({ error: "invalid_token" }, { status: 401 }),
  )

  try {
    const response = await authFetch(
      session,
      "https://api.testing.thesocialwire.app/v1/operations/overview",
    )
    expect(response.status).toBe(401)
    expect(invalidations).toEqual([])
  } finally {
    unsubscribe()
  }
})

test("invalidates a failed OAuth session before authenticated polling can continue", async () => {
  const did = "did:plc:operator"
  const failure = new TokenRefreshError(did, "The session was revoked")
  const invalidations: Array<{ did: string; cause: unknown }> = []
  const unsubscribe = onOAuthSessionInvalidated((invalidatedDid, cause) => {
    invalidations.push({ did: invalidatedDid, cause })
  })
  window.localStorage.setItem(storedDidKey, did)
  const session = createOperationsOAuthSession(
    async () => {
      throw failure
    },
    { did },
  )

  try {
    await expect(authFetch(session, "https://api.testing.thesocialwire.app/v1/operations/overview")).rejects.toBe(
      failure,
    )
    expect(window.localStorage.getItem(storedDidKey)).toBeNull()
    expect(invalidations).toEqual([{ did, cause: failure }])
  } finally {
    unsubscribe()
  }
})
