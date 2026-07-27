import { afterEach, describe, expect, it } from "bun:test";
import {
  TokenRefreshError,
  type OAuthSession,
} from "@atproto/oauth-client-browser";
import {
  authenticatedOAuthFetch,
  getStoredOAuthDid,
  isTerminalOAuthSessionError,
  localLoopbackCanonicalHref,
  localOAuthCanonicalHref,
  onOAuthSessionInvalidated,
  pathnameIsOAuthCallbackRoute,
  ATPROTO_LOOPBACK_CALLBACK_PATH,
} from "@/lib/auth";

afterEach(() => {
  window.localStorage.clear();
});

describe("auth", () => {
  it("pathnameIsOAuthCallbackRoute matches configured callback path", () => {
    expect(pathnameIsOAuthCallbackRoute("/callback")).toBe(true);
    expect(pathnameIsOAuthCallbackRoute(ATPROTO_LOOPBACK_CALLBACK_PATH)).toBe(
      true
    );
    expect(pathnameIsOAuthCallbackRoute("/read")).toBe(false);
  });

  it("localLoopbackCanonicalHref rewrites localhost to 127.0.0.1", () => {
    expect(
      localLoopbackCanonicalHref("http://localhost:3000/read?x=1")
    ).toBe("http://127.0.0.1:3000/read?x=1");
    expect(
      localLoopbackCanonicalHref("http://127.0.0.1:3000/callback")
    ).toBeNull();
  });

  it("localOAuthCanonicalHref aligns loopback client redirect host", () => {
    const clientId =
      "http://localhost?redirect_uri=http%3A%2F%2F127.0.0.1%3A3000%2Fcallback&scope=atproto";
    const href = localOAuthCanonicalHref(
      "http://localhost:3000/callback",
      clientId,
      ["http://127.0.0.1:3000/callback"]
    );
    expect(href).toBe("http://127.0.0.1:3000/callback");
  });

  it("localOAuthCanonicalHref returns null for non-loopback client_id", () => {
    expect(
      localOAuthCanonicalHref(
        "http://localhost:3000/callback",
        "https://thesocialwire.app/client-metadata.json",
        ["https://thesocialwire.app/callback"]
      )
    ).toBeNull();
  });

  it("invalidates a session when token refresh is terminal", async () => {
    const did = "did:plc:reader";
    const failure = new TokenRefreshError(did, "The session was revoked");
    const invalidations: Array<{ did: string; cause: unknown }> = [];
    const unsubscribe = onOAuthSessionInvalidated((invalidatedDid, cause) => {
      invalidations.push({ did: invalidatedDid, cause });
    });
    window.localStorage.setItem(
      "@@atproto/oauth-client-browser(sub)",
      did,
    );
    const session = {
      did,
      fetchHandler: async () => {
        throw failure;
      },
    } as unknown as OAuthSession;

    try {
      await expect(
        authenticatedOAuthFetch(session, "https://pds.example/xrpc/test"),
      ).rejects.toBe(failure);
      expect(isTerminalOAuthSessionError(failure)).toBe(true);
      expect(getStoredOAuthDid()).toBeNull();
      expect(invalidations).toEqual([{ did, cause: failure }]);
    } finally {
      unsubscribe();
    }
  });

  it("invalidates a final unauthorized response but not a DPoP nonce challenge", async () => {
    const did = "did:plc:reader";
    const invalidations: string[] = [];
    const unsubscribe = onOAuthSessionInvalidated((invalidatedDid) => {
      invalidations.push(invalidatedDid);
    });
    const responses = [
      new Response(null, {
        status: 401,
        headers: { "DPoP-Nonce": "expected-handshake" },
      }),
      new Response(null, { status: 401 }),
    ];
    const session = {
      did,
      fetchHandler: async () => responses.shift()!,
    } as unknown as OAuthSession;

    try {
      await authenticatedOAuthFetch(session, "https://pds.example/xrpc/test");
      expect(invalidations).toEqual([]);
      await authenticatedOAuthFetch(session, "https://pds.example/xrpc/test");
      expect(invalidations).toEqual([did]);
    } finally {
      unsubscribe();
    }
  });
});
