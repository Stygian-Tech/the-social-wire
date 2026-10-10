import { describe, expect, it } from "bun:test";
import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getBlueskyPostThread, setBlueskyPostEngagement } from "@/lib/blueskyPostClient";
const did = "did:plc:alice";
const uri = "at://did:plc:bob/app.bsky.feed.post/post";
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const moderation = { userDid: did, prefs: { labelers: [{ did: "did:web:labeler.test" }] } } as ModerationOpts;
describe("post actions transport", () => {
  it("reads threads via authenticated AppView with moderation subscriptions and cancellation", async () => {
    const signal = new AbortController().signal;
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://pds.test");
      expect(url.pathname).toBe("/xrpc/app.bsky.feed.getPostThread");
      expect(url.searchParams.get("uri")).toBe(uri);
      expect(new Headers(init?.headers).get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
      expect(new Headers(init?.headers).get("atproto-accept-labelers")).toContain("did:web:labeler.test");
      expect(init?.signal).toBe(signal);
      return Response.json({ thread: { $type: "app.bsky.feed.defs#notFoundPost", uri, notFound: true } });
    } } as unknown as OAuthSession;
    expect((await getBlueskyPostThread({ session, uri, moderation, signal })).thread).toMatchObject({ notFound: true });
  });
  it("creates and deletes likes and reposts directly on the viewer PDS with actual strong references", async () => {
    const calls: { path: string; body: Record<string, unknown> }[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("atproto-proxy")).toBeNull();
      const body = JSON.parse(await new Response(init?.body).text()); calls.push({ path, body });
      expect(body.repo).toBe(did);
      return Response.json(path.includes("createRecord") ? { uri: `at://${did}/${body.collection}/interaction`, cid } : {});
    } } as unknown as OAuthSession;
    for (const kind of ["like", "repost"] as const) {
      const created = await setBlueskyPostEngagement({ session, moderation, kind, uri, cid });
      expect(created).toBe(`at://${did}/app.bsky.feed.${kind}/interaction`);
      await setBlueskyPostEngagement({ session, moderation, kind, uri, cid, existingUri: created });
    }
    expect(calls.map(call => call.path)).toEqual(["/xrpc/com.atproto.repo.createRecord", "/xrpc/com.atproto.repo.deleteRecord", "/xrpc/com.atproto.repo.createRecord", "/xrpc/com.atproto.repo.deleteRecord"]);
    expect(calls[0]!.body.record).toMatchObject({ $type: "app.bsky.feed.like", subject: { uri, cid } });
    expect(calls[2]!.body.record).toMatchObject({ $type: "app.bsky.feed.repost", subject: { uri, cid } });
    expect(calls[1]!.body).toMatchObject({ collection: "app.bsky.feed.like", rkey: "interaction" });
  });
  it("refuses foreign interaction deletion, wrong collections, and stale moderation before transport", async () => {
    const session = { did, fetchHandler: async () => { throw new Error("unexpected transport"); } } as unknown as OAuthSession;
    for (const existingUri of ["at://did:plc:bob/app.bsky.feed.like/interaction", `at://${did}/app.bsky.feed.post/interaction`]) {
      await expect(setBlueskyPostEngagement({ session, moderation, kind: "like", uri, cid, existingUri })).rejects.toThrow("invalid record reference");
    }
    await expect(setBlueskyPostEngagement({ session, moderation, kind: "like", uri, cid: "invalid" })).rejects.toThrow("valid content reference");
    await expect(getBlueskyPostThread({ session, moderation: { ...moderation, userDid: "did:plc:bob" }, uri })).rejects.toThrow("account changed");
  });
});
