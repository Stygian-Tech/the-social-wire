import { afterEach, expect, test } from "bun:test"
import {
  OAuthResponseError,
  TokenRefreshError,
  type OAuthSession,
} from "@atproto/oauth-client-browser"
import {
  authFetch,
  isTerminalOAuthSessionError,
  onOAuthSessionInvalidated,
} from "@/lib/auth"

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

test("invalidates a failed OAuth session before authenticated polling can continue", async () => {
  const did = "did:plc:operator"
  const failure = new TokenRefreshError(did, "The session was revoked")
  const invalidations: Array<{ did: string; cause: unknown }> = []
  const unsubscribe = onOAuthSessionInvalidated((invalidatedDid, cause) => {
    invalidations.push({ did: invalidatedDid, cause })
  })
  window.localStorage.setItem(storedDidKey, did)
  const session = {
    did,
    fetchHandler: async () => {
      throw failure
    },
  } as unknown as OAuthSession

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
