import { describe, expect, it } from "bun:test";

import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";
import { buildWebOAuthClientMetadata } from "@/lib/oauthClientMetadata";

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
