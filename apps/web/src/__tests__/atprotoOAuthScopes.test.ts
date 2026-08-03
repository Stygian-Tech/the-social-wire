import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  AT_PROTO_OAUTH_SCOPES,
  BLUESKY_SOCIAL_PERMISSION_SCOPES,
  BLUESKY_SOCIAL_REPO_SCOPES,
  SKYREADER_REPO_SCOPES,
  SOCIAL_WIRE_REPO_SCOPES,
  STANDARD_SITE_SOCIAL_PERMISSION_SCOPE,
} from "@/lib/atprotoOAuthScopes";
import {
  USER_INPUT_BLOB_OAUTH_SCOPE,
  USER_INPUT_OAUTH_SCOPE,
} from "@/lib/userInputFeedback";

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
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain(
      "app.thesocialwire.entryReadState"
    );
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain(
      "com.thesocialwire.entryReadState"
    );
    expect(AT_PROTO_OAUTH_SCOPES).toContain("com.thesocialwire.folder");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.authCreatePosts");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.feed.like");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.feed.repost");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("link.latr.saved.external");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("com.latr.saved.external");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.skyreader.feed.subscription");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("site.standard.authSocial");
    expect(AT_PROTO_OAUTH_SCOPES).toContain(USER_INPUT_OAUTH_SCOPE);
  });

  it("defines collection-level permissions by feature", () => {
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("transition:generic");
    expect(
      AT_PROTO_OAUTH_SCOPES.split(" ")
        .filter((scope) => scope !== "atproto")
        .every(
          (scope) =>
            scope.startsWith("repo:") ||
            scope.startsWith("include:") ||
            scope.startsWith("blob:")
        )
    ).toBe(true);
    expect(SOCIAL_WIRE_REPO_SCOPES).toHaveLength(6);
    expect(BLUESKY_SOCIAL_PERMISSION_SCOPES).toEqual([
      "include:app.bsky.authCreatePosts?aud=did:web:api.bsky.app%23bsky_appview",
      "include:app.bsky.authDeleteContent?aud=did:web:api.bsky.app%23bsky_appview",
    ]);
    expect(
      BLUESKY_SOCIAL_REPO_SCOPES.every((scope) =>
        scope.startsWith("repo:app.bsky.")
      )
    ).toBe(true);
    expect(STANDARD_SITE_SOCIAL_PERMISSION_SCOPE).toBe(
      "include:site.standard.authSocial"
    );
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("repo:site.standard.graph.");
    expect(SKYREADER_REPO_SCOPES).toEqual([
      "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
    ]);
    expect(USER_INPUT_OAUTH_SCOPE).toBe("include:app.userinput.authFull");
    expect(USER_INPUT_BLOB_OAUTH_SCOPE).toBe("blob:*/*");
  });
});
