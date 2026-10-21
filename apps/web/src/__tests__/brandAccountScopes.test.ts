import { expect, it } from "bun:test";
import { BRAND_ACCOUNT_OAUTH_SCOPES } from "@/lib/brandAccounts/brandAccountScopes";
import { AT_PROTO_OAUTH_SCOPES, BLUESKY_DRAFT_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";
import { atprotoScopesForNetwork, resolveAtprotoNetwork } from "@/lib/atprotoNetwork";

it("requests only brand publishing, engagement and moderation permissions", () => {
  const scopes = BRAND_ACCOUNT_OAUTH_SCOPES.split(" ");
  expect(scopes).toContain("atproto");
  expect(scopes).toContain("repo:app.bsky.feed.post?action=create");
  expect(scopes).toContain("repo:app.bsky.feed.like?action=create&action=delete");
  expect(scopes).toContain("repo:app.bsky.feed.repost?action=create&action=delete");
  expect(scopes).toContain("blob:image/*");
  expect(scopes.some(scope => scope.startsWith("rpc:app.bsky.notification.listNotifications?"))).toBe(true);
  expect(scopes.some(scope => scope.startsWith("rpc:app.bsky.notification.updateSeen?"))).toBe(true);
  expect(scopes.filter(scope => scope.startsWith("repo:"))).toHaveLength(3);
  expect(scopes.some(scope => scope.startsWith("include:") || scope.includes("chat.bsky") || scope.includes("putPreferences"))).toBe(false);
  for (const scope of scopes) expect(AT_PROTO_OAUTH_SCOPES.split(" ")).toContain(scope);
});

it("keeps brand private draft grants equal to Web and rewrites only their network audience", () => {
  const brand = BRAND_ACCOUNT_OAUTH_SCOPES.split(" ");
  expect(brand.filter(scope => scope.includes("app.bsky.draft"))).toEqual([...BLUESKY_DRAFT_RPC_SCOPES]);
  const network = resolveAtprotoNetwork("local", { publicAppView: "https://appview.local.example", appViewDid: "did:web:appview.local.example" });
  for (const scopes of [AT_PROTO_OAUTH_SCOPES, BRAND_ACCOUNT_OAUTH_SCOPES]) {
    const local = atprotoScopesForNetwork(scopes, network).split(" ").filter(scope => scope.includes("app.bsky.draft"));
    expect(local).toEqual(BLUESKY_DRAFT_RPC_SCOPES.map(scope => scope.replace("did:web:api.bsky.app%23", "did:web:appview.local.example%23")));
    expect(local).toHaveLength(4);
  }
});
