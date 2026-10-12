import { describe, expect, it } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ModerationOpts } from "@atproto/api";
import { getBlueskyBookmarks, setBlueskyBookmark } from "@/lib/blueskyBookmarksClient";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";

const did = "did:plc:viewer";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:web:labels.test", labels: {} }], mutedWords: [], hiddenPosts: [] } };
const uri = "at://did:plc:other/app.bsky.feed.post/test";
function session(calls: { path: string; body?: unknown }[]): OAuthSession {
 return { did, fetchHandler: async (path: string, init?: RequestInit) => {
  const headers = new Headers(init?.headers);
  expect(headers.get("atproto-proxy")).toBe(`${getAtprotoNetwork().appViewDid}#bsky_appview`);
  expect(headers.get("atproto-accept-labelers")).toContain("did:web:labels.test");
  calls.push({ path, body: init?.body ? JSON.parse(await new Response(init.body).text()) : undefined });
  return path.includes("getBookmarks") ? Response.json({ bookmarks: [], cursor: "next" }) : new Response(null, { status: 200 });
 } } as unknown as OAuthSession;
}
describe("Bluesky Bookmarks", () => {
 it("uses private authenticated bookmarks with labelers, pagination and cancellation", async () => {
  const calls: { path: string }[] = [];
  const page = await getBlueskyBookmarks({ session: session(calls), moderation, cursor: "page", signal: new AbortController().signal });
  expect(page.cursor).toBe("next");
  expect(calls[0].path).toContain("cursor=page");
  expect(calls[0].path).toContain("limit=50");
 });
 it("saves a strong reference and removes only the requested bookmark", async () => {
  const calls: { path: string; body?: unknown }[] = [];
  const oauth = session(calls);
  await setBlueskyBookmark({ session: oauth, moderation, uri, cid: "bafyreia", saved: true });
  await setBlueskyBookmark({ session: oauth, moderation, uri, cid: "bafyreia", saved: false });
  expect(calls.map(call => call.body)).toEqual([{ uri, cid: "bafyreia" }, { uri }]);
 });
 it("rejects account mismatches and invalid post references before any request", async () => {
  const calls: { path: string }[] = [];
  const oauth = session(calls);
  await expect(getBlueskyBookmarks({ session: oauth, moderation: { ...moderation, userDid: "did:plc:other" } })).rejects.toThrow("account changed");
  await expect(setBlueskyBookmark({ session: oauth, moderation, uri: "https://bsky.app/post/foo", cid: "cid", saved: true })).rejects.toThrow("invalid post");
  await expect(setBlueskyBookmark({ session: oauth, moderation, uri, cid: "", saved: true })).rejects.toThrow("invalid post");
  expect(calls).toHaveLength(0);
 });
});
