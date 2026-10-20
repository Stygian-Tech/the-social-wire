import { afterEach, describe, expect, it, spyOn } from "bun:test";
import type { AppBskyDraftDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Network from "@/lib/atprotoNetwork";
import { createSocialDraft, deleteSocialDraft, listSocialDrafts, updateSocialDraft } from "@/lib/blueskyDraftClient";

const viewerDid = "did:plc:alice";
const id = "3l7g2w2w2w22a";
const draft: AppBskyDraftDefs.Draft & Record<string, unknown> = {
  deviceId: "e42cb606-0209-4a9d-86bf-097577fd4001", deviceName: "Web",
  posts: [{ text: "Unpublished 🦋", embedImages: [{ localRef: { path: "local/image.png" }, alt: "Image" }], futurePost: { keep: true } } as AppBskyDraftDefs.DraftPost],
  langs: ["en"], threadgateAllow: [{ $type: "app.bsky.feed.threadgate#mentionRule" }, { $type: "future.example#rule", preserve: true } as { $type: string }],
  futureDraft: { keep: [1, 2] },
};
const view = { id, draft, createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T01:00:00Z", futureView: true };
type Call = { url: URL; init: RequestInit };
function sessionFor(respond: (call: Call) => Response | Promise<Response>) {
  const calls: Call[] = [];
  const session = {
    did: viewerDid,
    fetchHandler: async (path: string, init: RequestInit) => {
      const call = { url: new URL(path, "https://alice.pds.example"), init };
      calls.push(call);
      return respond(call);
    },
  } as unknown as OAuthSession;
  return { session, calls };
}
type Actor = { session: OAuthSession; viewerDid: string; signal?: AbortSignal; assertCurrentActor?: () => void };
const operations = [
  (args: Actor) => listSocialDrafts(args),
  (args: Actor) => createSocialDraft({ ...args, draft }),
  (args: Actor) => updateSocialDraft({ ...args, id, draft }),
  (args: Actor) => deleteSocialDraft({ ...args, id }),
];
const restores: (() => void)[] = [];
afterEach(() => { for (const restore of restores.splice(0).reverse()) restore(); });
function success(index: number) {
  return index === 0 ? Response.json({ drafts: [view] }) : index === 1 ? Response.json({ id }) : new Response(null, { status: 200 });
}

describe("private Bluesky draft client", () => {
  it("uses only PDS OAuth AppView proxy RPCs with native payloads and abort signals", async () => {
    const directFetch = spyOn(globalThis, "fetch").mockImplementation(Object.assign(() => { throw new Error("No public requests"); }, { preconnect: globalThis.fetch.preconnect }));
    restores.push(() => directFetch.mockRestore());
    const controller = new AbortController();
    const { session, calls } = sessionFor(({ url }) => {
      if (url.pathname.endsWith("getDrafts")) return Response.json({ drafts: [view], cursor: "next+/=", futurePage: true });
      if (url.pathname.endsWith("createDraft")) return Response.json({ id });
      return new Response(null, { status: 200 });
    });
    const args = { session, viewerDid, signal: controller.signal };
    const expectedPage = { drafts: [view], cursor: "next+/=", futurePage: true };
    expect(await listSocialDrafts({ ...args, cursor: "opaque+/=" })).toEqual(expectedPage);
    expect(await createSocialDraft({ ...args, draft })).toEqual({ id });
    expect(await updateSocialDraft({ ...args, id, draft })).toBeUndefined();
    expect(await deleteSocialDraft({ ...args, id })).toBeUndefined();
    expect(calls.map(call => call.url.pathname)).toEqual([
      "/xrpc/app.bsky.draft.getDrafts", "/xrpc/app.bsky.draft.createDraft", "/xrpc/app.bsky.draft.updateDraft", "/xrpc/app.bsky.draft.deleteDraft",
    ]);
    expect(calls[0].url.searchParams.get("limit")).toBe("100");
    expect(calls[0].url.searchParams.get("cursor")).toBe("opaque+/=");
    expect(calls.map(call => call.init.method)).toEqual(["get", "post", "post", "post"]);
    expect(await new Response(calls[1].init.body).json()).toEqual({ draft });
    expect(await new Response(calls[2].init.body).json()).toEqual({ draft: { id, draft } });
    expect(await new Response(calls[3].init.body).json()).toEqual({ id });
    for (const call of calls) {
      expect(call.url.origin).toBe("https://alice.pds.example");
      expect(new Headers(call.init.headers).get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
      expect(call.init.signal).toBeInstanceOf(AbortSignal);
      expect(call.init.signal?.aborted).toBe(false);
    }
    expect(directFetch).not.toHaveBeenCalled();
  });

  it("bounds a stalled create even when the transport ignores cancellation", async () => {
    let expire!: () => void;
    const original = globalThis.setTimeout;
    const timer = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void, delay: number) => {
      if (delay === 20_000) { expire = callback; return original(() => {}, 60_000); }
      return original(callback, delay);
    }) as typeof setTimeout);
    restores.push(() => timer.mockRestore());
    const { session, calls } = sessionFor(() => new Promise(() => {}));
    const pending = createSocialDraft({ session, viewerDid, draft });
    expire();
    await expect(pending).rejects.toThrow("Draft Sync Timed Out");
    expect(calls).toHaveLength(1);
  });

  it("respects isolated network proxy routing without reaching the public AppView", async () => {
    const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue(Network.resolveAtprotoNetwork("local", {
      publicAppView: "https://appview.local.example", appViewDid: "did:web:appview.local.example", plcDirectory: "https://plc.local.example",
    }));
    restores.push(() => network.mockRestore());
    const { session, calls } = sessionFor(() => Response.json({ drafts: [] }));
    expect(await listSocialDrafts({ session, viewerDid })).toEqual({ drafts: [] });
    expect(new Headers(calls[0].init.headers).get("atproto-proxy")).toBe("did:web:appview.local.example#bsky_appview");
    expect(calls[0].url.origin).toBe("https://alice.pds.example");
    expect(calls[0].url.searchParams.has("cursor")).toBe(false);
  });

  for (const [index, operation] of operations.entries()) {
    it(`fails closed before request for mismatched, stale, or aborted actor (${index})`, async () => {
      const { session, calls } = sessionFor(() => { throw new Error("Must not request"); });
      await expect(operation({ session, viewerDid: "did:plc:bob" })).rejects.toThrow("account changed");
      await expect(operation({ session, viewerDid: "" })).rejects.toThrow("account changed");
      await expect(operation({ session, viewerDid, assertCurrentActor: () => { throw new Error("Stale actor"); } })).rejects.toThrow("Stale actor");
      await expect(operation({ session, viewerDid, signal: AbortSignal.abort() })).rejects.toMatchObject({ name: "AbortError" });
      expect(calls).toHaveLength(0);
    });
    for (const failed of [false, true]) {
      it(`guards actor changes after ${failed ? "failed" : "successful"} await (${index})`, async () => {
        let current = true;
        const { session, calls } = sessionFor(() => {
          current = false;
          if (failed) throw new Error("Uncertain result");
          return success(index);
        });
        await expect(operation({ session, viewerDid, assertCurrentActor: () => { if (!current) throw new Error("Stale actor"); } })).rejects.toThrow("Stale actor");
        expect(calls).toHaveLength(1);
      });
    }
    it(`rejects abort during the request even if transport completes (${index})`, async () => {
      const controller = new AbortController();
      const { session, calls } = sessionFor(() => { controller.abort(); return success(index); });
      await expect(operation({ session, viewerDid, signal: controller.signal })).rejects.toMatchObject({ name: "AbortError" });
      expect(calls).toHaveLength(1);
    });
  }

  it("rejects invalid IDs, drafts, and cursors before making any request", async () => {
    const { session, calls } = sessionFor(() => { throw new Error("Must not request"); });
    const args = { session, viewerDid };
    for (const invalid of ["", "not-a-tid", "at://did:plc:alice/app.bsky.feed.post/abc"]) {
      await expect(deleteSocialDraft({ ...args, id: invalid })).rejects.toThrow();
      await expect(updateSocialDraft({ ...args, id: invalid, draft })).rejects.toThrow();
    }
    for (const invalid of [{}, { posts: [{ text: 123 }] }, { posts: [{ text: "x".repeat(10001) }] }, { posts: [], deviceName: "x".repeat(101) }]) {
      await expect(createSocialDraft({ ...args, draft: invalid as AppBskyDraftDefs.Draft })).rejects.toThrow();
      await expect(updateSocialDraft({ ...args, id, draft: invalid as AppBskyDraftDefs.Draft })).rejects.toThrow();
    }
    await expect(listSocialDrafts({ ...args, cursor: 12 as unknown as string })).rejects.toThrow();
    expect(calls).toHaveLength(0);
  });

  it("rejects malformed pages rather than filtering records or stripping unknown fields", async () => {
    for (const page of [{}, { drafts: null }, { drafts: [view], cursor: 42 }, { drafts: [{ ...view, id: "bad" }] }, { drafts: [{ ...view, updatedAt: "bad" }] }, { drafts: [{ ...view, draft: { posts: [{}] } }] }, { drafts: [view, { ...view, id: "bad" }] }, { drafts: Array(101).fill(view) }]) {
      const { session } = sessionFor(() => Response.json(page));
      await expect(listSocialDrafts({ session, viewerDid })).rejects.toThrow();
    }
  });

  it("passes one page at a time and preserves an opaque continuation", async () => {
    const { session, calls } = sessionFor(({ url }) => Response.json(url.searchParams.has("cursor") ? { drafts: [] } : { drafts: [view], cursor: "opaque+/=" }));
    const first = await listSocialDrafts({ session, viewerDid });
    expect(calls).toHaveLength(1);
    expect(await listSocialDrafts({ session, viewerDid, cursor: first.cursor })).toEqual({ drafts: [] });
    expect(calls).toHaveLength(2);
    expect(calls[1].url.searchParams.get("cursor")).toBe("opaque+/=");
  });

  it("rechecks session DID after the request", async () => {
    const { session } = sessionFor(() => {
      Object.defineProperty(session, "did", { value: "did:plc:bob" });
      return Response.json({ drafts: [view] });
    });
    await expect(listSocialDrafts({ session, viewerDid })).rejects.toThrow("account changed");
  });

  it("never retries uncertain creates or falls back to repo publishing", async () => {
    for (const status of [401, 403, 429, 500, 503, "network", "malformed", "bad-id"] as const) {
      const { session, calls } = sessionFor(() => {
        if (status === "network") throw new Error("Connection lost after submission");
        if (status === "malformed") return Response.json({});
        if (status === "bad-id") return Response.json({ id: "bad" });
        return Response.json({ error: "Unavailable", message: "Draft request failed" }, { status });
      });
      await expect(createSocialDraft({ session, viewerDid, draft })).rejects.toThrow();
      expect(calls).toHaveLength(1);
      expect(calls[0].url.pathname).toBe("/xrpc/app.bsky.draft.createDraft");
    }
  });
});
