import { describe, expect, it } from "bun:test";

import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";
import {
  buildWebOAuthClientMetadata,
  hostedOAuthClientIdForOrigin,
  resolveHostedOAuthClientId,
} from "@/lib/oauthClientMetadata";

describe("buildWebOAuthClientMetadata", () => {
  it("uses the request origin for client_id and redirect_uris", () => {
    const metadata = buildWebOAuthClientMetadata("https://preview.example.com");
    expect(metadata.client_id).toBe(
      "https://preview.example.com/oauth-client-metadata.json",
    );
    expect(metadata.redirect_uris).toEqual([
      "https://preview.example.com/callback",
    ]);
    expect(metadata.scope).toBe(AT_PROTO_OAUTH_SCOPES);
  });
});

describe("hostedOAuthClientIdForOrigin", () => {
  it("uses same-origin metadata for the hosted testing web host", () => {
    expect(
      hostedOAuthClientIdForOrigin("https://testing.thesocialwire.app"),
    ).toBe("https://testing.thesocialwire.app/oauth-client-metadata.json");
  });

  it("uses same-origin metadata for unmapped preview hosts", () => {
    expect(hostedOAuthClientIdForOrigin("https://preview.example.com")).toBe(
      "https://preview.example.com/oauth-client-metadata.json",
    );
  });

  it("uses same-origin metadata for prod even when API base env is set", () => {
    const prevApi = process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL =
      "https://api.thesocialwire.app";
    try {
      expect(hostedOAuthClientIdForOrigin("https://thesocialwire.app")).toBe(
        "https://thesocialwire.app/oauth-client-metadata.json",
      );
    } finally {
      if (prevApi === undefined)
        delete process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
      else process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = prevApi;
    }
  });
});

describe("resolveHostedOAuthClientId", () => {
  it("honors NEXT_PUBLIC_ATPROTO_CLIENT_ID for an intentional override", () => {
    const prevClientId = process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID;
    const prevApi = process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
    process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID =
      "https://gateway-dev.example.up.railway.app/oauth-client-metadata.json";
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL =
      "https://api.testing.thesocialwire.app";
    try {
      expect(
        resolveHostedOAuthClientId("https://testing.thesocialwire.app"),
      ).toBe(
        "https://gateway-dev.example.up.railway.app/oauth-client-metadata.json",
      );
    } finally {
      if (prevClientId === undefined)
        delete process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID;
      else process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID = prevClientId;
      if (prevApi === undefined)
        delete process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
      else process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = prevApi;
    }
  });

  it("honors NEXT_PUBLIC_ATPROTO_CLIENT_ID on unmapped preview hosts", () => {
    const prevClientId = process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID;
    process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID =
      "https://custom.example/client-metadata.json";
    try {
      expect(resolveHostedOAuthClientId("https://preview.example.com")).toBe(
        "https://custom.example/client-metadata.json",
      );
    } finally {
      if (prevClientId === undefined)
        delete process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID;
      else process.env.NEXT_PUBLIC_ATPROTO_CLIENT_ID = prevClientId;
    }
  });
});
