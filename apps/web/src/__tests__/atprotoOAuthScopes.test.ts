import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  AT_PROTO_OAUTH_SCOPES,
  ARTICLE_PUBLISHING_SCOPES,
  BLUESKY_SOCIAL_REPO_SCOPES,
  BLUESKY_SOCIAL_RPC_SCOPES,
  SKYREADER_REPO_SCOPES,
  SOCIAL_WIRE_REPO_SCOPES,
  SEMBLE_REPO_OAUTH_SCOPES,
  STANDARD_SITE_SOCIAL_PERMISSION_SCOPE,
  WIRE_FEEDBACK_REPO_SCOPE,
  WIRE_MODERATION_RPC_SCOPES,
} from "@/lib/atprotoOAuthScopes";
import {
  USER_INPUT_BLOB_OAUTH_SCOPE,
  USER_INPUT_OAUTH_SCOPE,
} from "@/lib/userInputFeedback";
import { STANDARD_READER_LIST_SAVE_SCOPE, STANDARD_READER_LIST_WRITE_SCOPE } from "@/lib/standardReaderList";

describe("atprotoOAuthScopes", () => {
  it("grants viewer-aware Social reads at the AppView audience without generic permissions", () => {
    for (const method of ["app.bsky.feed.getTimeline", "app.bsky.feed.getFeed", "app.bsky.feed.getFeedSkeleton", "app.bsky.feed.getFeedGenerators", "app.bsky.feed.getListFeed", "app.bsky.labeler.getServices"]) {
      const scope = `rpc:${method}?aud=did:web:api.bsky.app%23bsky_appview`;
      expect([...BLUESKY_SOCIAL_RPC_SCOPES] as string[]).toContain(scope);
      expect(AT_PROTO_OAUTH_SCOPES.split(" ")).toContain(scope);
    }
  });
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
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.thesocialwire.wireFeedback");
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain(
      "app.thesocialwire.entryReadState"
    );
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain(
      "com.thesocialwire.entryReadState"
    );
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("repo:com.thesocialwire.");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("repo:app.bsky.feed.post?action=create");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.feed.like");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.bsky.feed.repost");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("link.latr.saved.external");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("com.latr.saved.external");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("app.skyreader.feed.subscription");
    expect(AT_PROTO_OAUTH_SCOPES).toContain("site.standard.authSocial");
    expect(AT_PROTO_OAUTH_SCOPES).toContain(USER_INPUT_OAUTH_SCOPE);
    expect(AT_PROTO_OAUTH_SCOPES.split(" ")).toContain(STANDARD_READER_LIST_SAVE_SCOPE);
    expect(AT_PROTO_OAUTH_SCOPES.split(" ")).toContain(STANDARD_READER_LIST_WRITE_SCOPE);
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
            scope.startsWith("rpc:") ||
            scope.startsWith("blob:")
        )
    ).toBe(true);
    expect(SOCIAL_WIRE_REPO_SCOPES).toHaveLength(5);
    expect(AT_PROTO_OAUTH_SCOPES.split(" ")).toContain("repo:app.thesocialwire.preferences?action=create&action=update");
    expect(AT_PROTO_OAUTH_SCOPES.split(" ")).toContain("repo:app.thesocialwire.readState?action=create&action=update");
    expect(WIRE_FEEDBACK_REPO_SCOPE).toContain(
      "app.thesocialwire.wireFeedback"
    );
    expect(BLUESKY_SOCIAL_REPO_SCOPES).toEqual([
      "repo:app.bsky.feed.post?action=create",
      "repo:app.bsky.graph.list?action=create&action=update&action=delete",
      "repo:app.bsky.graph.listitem?action=create&action=delete",
      "repo:app.bsky.feed.like?action=create&action=delete",
      "repo:app.bsky.feed.repost?action=create&action=delete",
    ]);
    expect(ARTICLE_PUBLISHING_SCOPES).toEqual([
      "repo:site.standard.document?action=create",
      "repo:app.offprint.document.article?action=create",
      "repo:blog.pckt.document?action=create",
      "blob:text/markdown",
      "blob:application/json",
    ]);
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("include:app.bsky.authCreatePosts");
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("include:app.bsky.authDeleteContent");
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("blob:*/*");
    expect(STANDARD_SITE_SOCIAL_PERMISSION_SCOPE).toBe(
      "include:site.standard.authSocial"
    );
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("repo:site.standard.graph.");
    expect(SKYREADER_REPO_SCOPES).toEqual([
      "repo:app.skyreader.feed.subscription?action=create&action=update&action=delete",
    ]);
    expect(USER_INPUT_OAUTH_SCOPE).toBe("repo:app.userinput.discussion?action=create");
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("include:app.userinput.authFull");
    expect(USER_INPUT_BLOB_OAUTH_SCOPE).toBe("blob:image/*");
    expect(WIRE_MODERATION_RPC_SCOPES).toEqual([
      "rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23bsky_appview",
      "rpc:app.bsky.graph.getBlocks?aud=did:web:api.bsky.app%23bsky_appview",
      "rpc:app.bsky.graph.getMutes?aud=did:web:api.bsky.app%23bsky_appview",
      "rpc:app.bsky.graph.getListMutes?aud=did:web:api.bsky.app%23bsky_appview",
      "rpc:app.bsky.graph.getListBlocks?aud=did:web:api.bsky.app%23bsky_appview",
      "rpc:app.bsky.graph.getList?aud=did:web:api.bsky.app%23bsky_appview",
    ]);
  });

  it("grants only implemented Semble writes and no collection administration", () => {
    expect(SEMBLE_REPO_OAUTH_SCOPES).toEqual([
      "repo:network.cosmik.card?action=create&action=update",
      "repo:network.cosmik.collectionLink?action=create&action=delete",
      "repo:network.cosmik.collectionLinkRemoval?action=create",
      "repo:network.cosmik.connection?action=create&action=update",
    ]);
    for (const scope of SEMBLE_REPO_OAUTH_SCOPES) expect(AT_PROTO_OAUTH_SCOPES.split(" ")).toContain(scope);
    expect(AT_PROTO_OAUTH_SCOPES).not.toContain("repo:network.cosmik.collection?");
  });
});

it("keeps published native OAuth scopes exactly aligned with the native authorization request", () => {
  const metadata = JSON.parse(readFileSync(join(import.meta.dir, "../../public/ios-client-metadata.json"), "utf8")) as { scope: string };
  const native = readFileSync(join(import.meta.dir, "../../../apple/SocialWire/Services/ATProtoOAuthService.swift"), "utf8");
  const scopeArray = native.split("static let scopes = [")[1]?.split("].joined(separator:")[0];
  expect(scopeArray).toBeDefined();
  const nativeScopes = [...scopeArray!.matchAll(/^\s*"([^"\n]+)"/gm)].map(match => match[1]);
  expect(metadata.scope).toBe(nativeScopes.join(" "));
  expect(nativeScopes).toContain("repo:app.thesocialwire.readState?action=create&action=update");
  expect(nativeScopes).toContain("repo:app.thesocialwire.readStateChunk?action=create&action=update&action=delete");
});
