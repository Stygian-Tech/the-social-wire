import { describe, expect, it } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createBlueskyPost, postTextLength } from "@/lib/blueskyComposeClient";

const did = "did:plc:alice";
const result = { uri: `at://${did}/app.bsky.feed.post/one`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" };
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
