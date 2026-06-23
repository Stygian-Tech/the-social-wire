import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";

describe("atprotoOAuthScopes", () => {
  it("matches public client-metadata.json scope string", () => {
    const metadataPath = join(
      import.meta.dir,
      "../../public/client-metadata.json"
    );
    const metadata = JSON.parse(readFileSync(metadataPath, "utf8")) as {
      scope: string;
    };
    expect(AT_PROTO_OAUTH_SCOPES).toBe(metadata.scope);
  });

  it("includes required repo collections", () => {
    expect(AT_PROTO_OAUTH_SCOPES).toContain("atproto");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.thesocialwire.folder");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.thesocialwire.entryReadState");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("com.thesocialwire.folder");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.feed.post");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.feed.like");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.feed.repost");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("link.latr.saved.external");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("com.latr.saved.external");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.skyreader.feed.subscription");
  });
});
