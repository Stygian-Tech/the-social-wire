import { expect, it } from "bun:test";
import { BRAND_ACCOUNT_OAUTH_SCOPES } from "@/lib/brandAccounts/brandAccountScopes";
import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";

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
