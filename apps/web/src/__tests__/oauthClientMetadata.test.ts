import { describe, expect, it } from "bun:test";

import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";
import {
  buildWebOAuthClientMetadata,
  gatewayWebOAuthClientMetadataUrl,
  hostedOAuthClientIdForOrigin,
  inferGatewayApiBase,
} from "@/lib/oauthClientMetadata";

describe("buildWebOAuthClientMetadata", () => {
  it("uses the request origin for client_id and redirect_uris", () => {
    const metadata = buildWebOAuthClientMetadata(
      "https://preview.example.vercel.app"
    );
    expect(metadata.client_id).toBe(
      "https://preview.example.vercel.app/client-metadata.json"
    );
    expect(metadata.redirect_uris).toEqual([
      "https://preview.example.vercel.app/callback",
    ]);
    expect(metadata.scope).toBe(AT_PROTO_OAUTH_SCOPES);
  });
});

describe("inferGatewayApiBase", () => {
  it("maps testing web host to the testing API gateway", () => {
    expect(
      inferGatewayApiBase("https://testing.thesocialwire.app")
    ).toBe("https://api.testing.thesocialwire.app");
  });
});

describe("hostedOAuthClientIdForOrigin", () => {
  it("uses the public API gateway for deployment-protected testing web host", () => {
    expect(
      hostedOAuthClientIdForOrigin("https://testing.thesocialwire.app")
    ).toBe("https://api.testing.thesocialwire.app/oauth/client-metadata.json");
  });

  it("uses same-origin metadata for unmapped preview hosts", () => {
    expect(
      hostedOAuthClientIdForOrigin("https://preview.example.vercel.app")
    ).toBe("https://preview.example.vercel.app/client-metadata.json");
  });
});

describe("gatewayWebOAuthClientMetadataUrl", () => {
  it("builds the gateway discoverable client_id URL", () => {
    expect(
      gatewayWebOAuthClientMetadataUrl("https://api.testing.thesocialwire.app")
    ).toBe("https://api.testing.thesocialwire.app/oauth/client-metadata.json");
  });
});
