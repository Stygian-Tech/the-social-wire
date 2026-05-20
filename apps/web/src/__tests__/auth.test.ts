import { describe, expect, it } from "bun:test";
import {
  localLoopbackCanonicalHref,
  localOAuthCanonicalHref,
  pathnameIsOAuthCallbackRoute,
  ATPROTO_LOOPBACK_CALLBACK_PATH,
} from "@/lib/auth";

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
});
