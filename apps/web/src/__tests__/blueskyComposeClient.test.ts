import { describe, expect, it } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { AppBskyFeedDefs } from "@atproto/api";
import { createBlueskyPost, postTextLength, prepareBlueskyPost } from "@/lib/blueskyComposeClient";
import { newThreadPublication } from "@/lib/blueskyThreadClient";
import { AppBskyFeedPost } from "@atproto/api";

const did = "did:plc:alice";
const result = { uri: `at://${did}/app.bsky.feed.post/one`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" };
const replyTo: AppBskyFeedDefs.PostView = {
  uri: "at://did:plc:bob/app.bsky.feed.post/target",
  cid: result.cid,
  author: { did: "did:plc:bob", handle: "bob.test" },
  record: { $type: "app.bsky.feed.post", text: "Original Post", createdAt: "2026-10-11T00:00:00Z" },
  indexedAt: "2026-10-11T00:00:00Z",
};
type Request = { method: string; headers: Headers; body?: Record<string, unknown> };
function sessionFor(respond: (request: Request) => unknown | Promise<unknown>): OAuthSession {
  return {
    did,
    fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://alice.pds.example");
      const response = await respond({ method: url.pathname.split("/").at(-1)!, headers: new Headers(init?.headers), body: init?.body ? await new Response(init.body).json() : undefined });
      return response instanceof Response ? response : Response.json(response);
    },
  } as unknown as OAuthSession;
}

describe("Bluesky post creation", () => {
  const linkPreview = { uri: "https://example.com/story", title: "A Story", description: "A summary" };
  it("constructs a native external card when its URL is absent from imported text", async () => {
    const session = sessionFor(() => { throw new Error("Unexpected request"); });
    const record = await prepareBlueskyPost({ session, text: "Read this", linkPreview, nativeDraftPost: { text: "Read this", embedExternals: [{ uri: linkPreview.uri }] } });
    expect(record.text).toBe("Read this");
    expect(record.embed).toMatchObject({ $type: "app.bsky.embed.external", external: { uri: linkPreview.uri } });
    expect(record.facets).toBeUndefined();
    expect(AppBskyFeedPost.validateRecord(record).success).toBe(true);
  });
  it("omits explicitly removed native cards even when the URL remains in text", async () => {
    const session = sessionFor(() => { throw new Error("Unexpected request"); });
    for (const text of ["Read this", linkPreview.uri]) {
      const record = await prepareBlueskyPost({ session, text, linkPreview, removedLinkUrl: linkPreview.uri, nativeDraftPost: { text, embedExternals: [{ uri: linkPreview.uri }] } });
      expect(record).not.toHaveProperty("embed");
    }
  });
  it("keeps unsupported and stale previews out of constructed records", async () => {
    const session = sessionFor(() => { throw new Error("Unexpected request"); });
    for (const uri of ["javascript:alert(1)", "ftp://example.com/story", "https://user:password@example.com/story"]) {
      const record = await prepareBlueskyPost({ session, text: "Read this", linkPreview: { ...linkPreview, uri }, nativeDraftPost: { text: "Read this", embedExternals: [{ uri }] } });
      expect(record).not.toHaveProperty("embed");
    }
    for (const nativeDraftPost of [undefined, { text: "Read this", embedExternals: [{ uri: "https://example.com/other" }] }]) {
      for (const text of ["Read this", "https://example.com/replacement"]) {
        const record = await prepareBlueskyPost({ session, text, linkPreview, nativeDraftPost });
        expect(record).not.toHaveProperty("embed");
      }
    }
  });
  it("preserves imported cards through single and multi-post publication preparation", async () => {
    for (const count of [1, 2]) {
      const publication = newThreadPublication(did, Array.from({ length: count }, (_, index) => ({
        id: String(index), text: "Read this", linkPreview, nativeDraftPost: { text: "Read this", embedExternals: [{ uri: linkPreview.uri }] },
      })));
      let writes = 0;
      const session = sessionFor(request => {
        expect(request.method).toBe("com.atproto.repo.createRecord");
        const record = request.body!.record as AppBskyFeedPost.Record;
        expect(record.embed).toMatchObject({ $type: "app.bsky.embed.external", external: { uri: linkPreview.uri } });
        expect(AppBskyFeedPost.validateRecord(record).success).toBe(true);
        if (writes) expect(record.reply?.parent.uri).toBe(result.uri);
        writes++;
        return result;
      });
      await createBlueskyPost({ session, text: "Read this", publication });
      expect(writes).toBe(count);
      for (const segment of publication.segments) expect(segment.record?.embed).toMatchObject({ external: { uri: linkPreview.uri } });
    }
  });
  it("publishes the example as linked label text with the card and UTF-8 offsets intact", async () => {
    const preview = { uri: "https://labs.xbox.com/", title: "XBOX Labs", description: "Explore" };
    let writes = 0;
    const session = sessionFor(request => {
      writes++;
      expect(request.method).toBe("com.atproto.repo.createRecord");
      expect(AppBskyFeedPost.validateRecord(request.body!.record).success).toBe(true);
      expect(request.body!.record).toMatchObject({ text: "🌎 XBOX Labs is interesting\n\nCurious to see", facets: [{ index: { byteStart: 5, byteEnd: 14 }, features: [{ uri: preview.uri }] }], embed: { external: preview } });
      return result;
    });
    await createBlueskyPost({ session, text: "🌎 [XBOX Labs](labs.xbox.com) is interesting\n\nCurious to see", linkPreview: preview });
    expect(writes).toBe(1);
  });
  it("does not resolve handles inside code or explicit link labels", async () => {
    const session = sessionFor(request => {
      expect(request.method).toBe("com.atproto.repo.createRecord");
      expect(request.body!.record).toMatchObject({ text: "@code.test @label.test", facets: [{ features: [{ uri: "https://target.test/" }] }] });
      return result;
    });
    await createBlueskyPost({ session, text: "`@code.test` [@label.test](https://target.test)" });
    await expect(createBlueskyPost({ session, text: "[](https://example.com)" })).rejects.toThrow("Write Something");
  });
  it("serializes a valid external embed alongside URL facets on a direct PDS post", async () => {
    const session = sessionFor(request => {
      const record = request.body!.record;
      expect(AppBskyFeedPost.validateRecord(record).success).toBe(true);
      expect(record).toMatchObject({ embed: { $type: "app.bsky.embed.external", external: linkPreview }, facets: [{ features: [{ uri: linkPreview.uri }] }] });
      return result;
    });
    await createBlueskyPost({ session, text: linkPreview.uri, linkPreview });
  });
  it("retains quote references with an external card in recordWithMedia", async () => {
    const session = sessionFor(request => {
      const record = request.body!.record;
      expect(AppBskyFeedPost.validateRecord(record).success).toBe(true);
      expect(record).toMatchObject({ embed: { $type: "app.bsky.embed.recordWithMedia", record: { $type: "app.bsky.embed.record", record: { uri: replyTo.uri, cid: replyTo.cid } }, media: { $type: "app.bsky.embed.external", external: linkPreview } } });
      return result;
    });
    await createBlueskyPost({ session, text: linkPreview.uri, linkPreview, quoteTo: replyTo });
  });
  it("preserves reply ancestry while attaching an external card", async () => {
    const session = sessionFor(request => {
      expect(request.body!.record).toMatchObject({ reply: { parent: { uri: replyTo.uri } }, embed: { $type: "app.bsky.embed.external", external: linkPreview } });
      return result;
    });
    await createBlueskyPost({ session, text: linkPreview.uri, linkPreview, replyTo });
  });
  it("omits removed and obsolete previews without blocking text-only posting", async () => {
    let writes = 0;
    const session = sessionFor(request => { writes++; expect(request.body!.record).not.toHaveProperty("embed"); return result; });
    await createBlueskyPost({ session, text: linkPreview.uri });
    await createBlueskyPost({ session, text: "https://example.com/replacement", linkPreview });
    expect(writes).toBe(2);
  });
  it("counts graphemes and UTF-8 bytes independently", () => {
    expect(postTextLength("👩‍👩‍👧‍👦é")).toEqual({ graphemes: 2, bytes: 28 });
  });
  it("rejects empty and excessive text before any network request", async () => {
    let calls = 0;
    const session = sessionFor(() => { calls++; return result; });
    for (const text of ["", " \n\t", "a".repeat(301), "a" + "\u0301".repeat(1500)]) await expect(createBlueskyPost({ session, text })).rejects.toThrow();
    expect(calls).toBe(0);
  });
  it("accepts the native boundary and preserves exact source on the direct PDS write", async () => {
    const text = ` ${"é".repeat(298)} `;
    const session = sessionFor(request => {
      expect(request.method).toBe("com.atproto.repo.createRecord");
      expect(request.headers.get("atproto-proxy")).toBeNull();
      expect(request.body).toMatchObject({ repo: did, collection: "app.bsky.feed.post", record: { text } });
      expect(Number.isNaN(Date.parse((request.body!.record as { createdAt: string }).createdAt))).toBe(false);
      return result;
    });
    expect(await createBlueskyPost({ session, text })).toEqual(result);
  });
  it("resolves mentions through authenticated AppView and sends native UTF-8 facets", async () => {
    const requests: Request[] = [];
    const session = sessionFor(request => {
      requests.push(request);
      if (request.method === "com.atproto.identity.resolveHandle") {
        expect(request.headers.get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
        return { did: "did:plc:bob" };
      }
      return result;
    });
    await createBlueskyPost({ session, text: "é @bob.test https://example.com #hello" });
    expect(requests.map(request => request.method)).toEqual(["com.atproto.identity.resolveHandle", "com.atproto.repo.createRecord"]);
    const record = requests[1]!.body!.record as { facets: { index: { byteStart: number; byteEnd: number }; features: Record<string, string>[] }[] };
    expect(record.facets).toHaveLength(3);
    expect(record.facets[0]).toMatchObject({ index: { byteStart: 3, byteEnd: 12 }, features: [{ $type: "app.bsky.richtext.facet#mention", did: "did:plc:bob" }] });
    expect(record.facets[1]!.features[0]).toMatchObject({ $type: "app.bsky.richtext.facet#link", uri: "https://example.com" });
    expect(record.facets[2]!.features[0]).toMatchObject({ $type: "app.bsky.richtext.facet#tag", tag: "hello" });
  });
  it("keeps unresolved mentions plain without invalid DID facets", async () => {
    const session = sessionFor(request => {
      if (request.method === "com.atproto.identity.resolveHandle") return Response.json({ error: "HandleNotFound", message: "Unknown handle" }, { status: 400 });
      expect(request.body!.record).toMatchObject({ text: "@missing.test" });
      expect(request.body!.record).not.toHaveProperty("facets");
      return result;
    });
    await createBlueskyPost({ session, text: "@missing.test" });
  });
  it("posts a reply with the exact target as root and parent directly to the viewer PDS", async () => {
    const session = sessionFor(request => {
      expect(request.method).toBe("com.atproto.repo.createRecord");
      expect(request.headers.get("atproto-proxy")).toBeNull();
      expect(request.body).toMatchObject({ repo: did, collection: "app.bsky.feed.post", record: {
        text: "Reply Text", reply: { root: { uri: replyTo.uri, cid: replyTo.cid }, parent: { uri: replyTo.uri, cid: replyTo.cid } },
      } });
      return result;
    });
    expect(await createBlueskyPost({ session, text: "Reply Text", replyTo })).toEqual(result);
  });
  it("posts a native quote embed directly to the viewer PDS while resolving facets", async () => {
    const requests: Request[] = [];
    const session = sessionFor(request => {
      requests.push(request);
      if (request.method === "com.atproto.identity.resolveHandle") return { did: "did:plc:bob" };
      expect(request.headers.get("atproto-proxy")).toBeNull();
      expect(request.body).toMatchObject({ repo: did, collection: "app.bsky.feed.post", record: {
        text: "@bob.test Quote", embed: { $type: "app.bsky.embed.record", record: { uri: replyTo.uri, cid: replyTo.cid } },
        facets: [{ features: [{ $type: "app.bsky.richtext.facet#mention", did: "did:plc:bob" }] }],
      } });
      expect(request.body!.record).not.toHaveProperty("reply");
      return result;
    });
    expect(await createBlueskyPost({ session, text: "@bob.test Quote", quoteTo: replyTo })).toEqual(result);
    expect(requests.map(request => request.method)).toEqual(["com.atproto.identity.resolveHandle", "com.atproto.repo.createRecord"]);
  });
  it("rejects disabled quotes, invalid references, and combined reply and quote before network", async () => {
    let requests = 0;
    const session = sessionFor(() => { requests++; return result; });
    const invalidTargets = [
      { ...replyTo, viewer: { embeddingDisabled: true } },
      { ...replyTo, uri: "https://bsky.app/profile/bob.test/post/target" },
      { ...replyTo, uri: "at://did:plc:bob/app.bsky.feed.like/target" },
      { ...replyTo, cid: "" },
    ];
    for (const target of invalidTargets) await expect(createBlueskyPost({ session, text: "@bob.test Quote", quoteTo: target })).rejects.toThrow();
    await expect(createBlueskyPost({ session, text: "@bob.test Quote", replyTo, quoteTo: replyTo })).rejects.toThrow("Choose either a reply or a quote post.");
    expect(requests).toBe(0);
  });
  it("keeps quote account guards before lookup and before the PDS write", async () => {
    let requests = 0, checks = 0;
    const session = sessionFor(() => { requests++; return { did: "did:plc:bob" }; });
    await expect(createBlueskyPost({ session, text: "@bob.test Quote", quoteTo: replyTo, assertCurrentAccount: () => { if (++checks === 2) throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
    expect(requests).toBe(1);
    expect(checks).toBe(2);
  });
  it("preserves thread ancestry when replying to a reply and still resolves mention facets", async () => {
    const root = { uri: "at://did:plc:carol/app.bsky.feed.post/root", cid: result.cid };
    const nested = { ...replyTo, record: { ...replyTo.record, reply: { root, parent: root } } };
    const requests: Request[] = [];
    const session = sessionFor(request => {
      requests.push(request);
      if (request.method === "com.atproto.identity.resolveHandle") return { did: "did:plc:bob" };
      expect(request.body!.record).toMatchObject({
        reply: { root, parent: { uri: nested.uri, cid: nested.cid } },
        facets: [{ features: [{ $type: "app.bsky.richtext.facet#mention", did: "did:plc:bob" }] }],
      });
      return result;
    });
    await createBlueskyPost({ session, text: "@bob.test Reply", replyTo: nested });
    expect(requests.map(request => request.method)).toEqual(["com.atproto.identity.resolveHandle", "com.atproto.repo.createRecord"]);
  });
  it("rejects disabled replies and malformed target or root references before facet lookup or writes", async () => {
    let requests = 0;
    const session = sessionFor(() => { requests++; return result; });
    const root = { uri: "at://did:plc:carol/app.bsky.feed.post/root", cid: result.cid };
    const invalidTargets = [
      { ...replyTo, viewer: { replyDisabled: true } },
      { ...replyTo, uri: "https://bsky.app/profile/bob.test/post/target" },
      { ...replyTo, cid: "" },
      { ...replyTo, record: { $type: "app.bsky.feed.like", createdAt: "2026-10-11T00:00:00Z" } },
      { ...replyTo, record: { ...replyTo.record, reply: { root: { ...root, uri: "at://did:plc:carol/app.bsky.feed.like/root" }, parent: root } } },
      { ...replyTo, record: { ...replyTo.record, reply: { root: { ...root, cid: "" }, parent: root } } },
    ];
    for (const target of invalidTargets) await expect(createBlueskyPost({ session, text: "@bob.test Reply", replyTo: target })).rejects.toThrow();
    expect(requests).toBe(0);
  });
  it("keeps reply account guards before lookup and before the PDS write", async () => {
    let requests = 0, checks = 0;
    const session = sessionFor(() => { requests++; return { did: "did:plc:bob" }; });
    await expect(createBlueskyPost({ session, text: "@bob.test Reply", replyTo, assertCurrentAccount: () => { if (++checks === 2) throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
    expect(requests).toBe(1);
    expect(checks).toBe(2);
  });
  it("guards account identity before network and after async resolution, before writing", async () => {
    let requests = 0, checks = 0;
    const session = sessionFor(() => { requests++; return { did: "did:plc:bob" }; });
    await expect(createBlueskyPost({ session, text: "Hello", assertCurrentAccount: () => { throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
    expect(requests).toBe(0);
    await expect(createBlueskyPost({ session, text: "@bob.test", assertCurrentAccount: () => { if (++checks === 2) throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
    expect(checks).toBe(2);
    expect(requests).toBe(1);
  });
  it("propagates PDS scope rejection without retrying the post", async () => {
    let writes = 0;
    const session = sessionFor(() => { writes++; return Response.json({ error: "InvalidToken", message: "Missing required scope" }, { status: 403 }); });
    await expect(createBlueskyPost({ session, text: "Hello" })).rejects.toMatchObject({ status: 403 });
    expect(writes).toBe(1);
  });
});
