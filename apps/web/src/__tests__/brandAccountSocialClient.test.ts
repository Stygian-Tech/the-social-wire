import { describe, expect, it } from "bun:test";
import type { AppBskyFeedDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { publishBrandPost } from "@/lib/brandAccounts/brandAccountSocialClient";

const did = "did:plc:brand";
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const target = { uri: "at://did:plc:customer/app.bsky.feed.post/reply", cid, author: { did: "did:plc:customer", handle: "customer.test" }, record: { $type: "app.bsky.feed.post", text: "Question", createdAt: "2026-10-11T12:00:00Z", reply: { parent: { uri: "at://did:plc:brand/app.bsky.feed.post/old", cid }, root: { uri: "at://did:plc:brand/app.bsky.feed.post/root", cid } } } } as unknown as AppBskyFeedDefs.PostView;
function sessionFor(respond: (path: string, body: Record<string, unknown>, init?: RequestInit) => unknown | Promise<unknown>) {
  return { did, fetchHandler: async (path: string, init?: RequestInit) => Response.json(await respond(path, init?.body ? await new Response(init.body).json() : {}, init)) } as unknown as OAuthSession;
}
describe("brand post publishing", () => {
  it("writes on the brand PDS with immediate reply parent and original root, preserving source", async () => {
    const session = sessionFor((path, body, init) => {
      expect(path).toBe("/xrpc/com.atproto.repo.createRecord"); expect(body.repo).toBe(did);
      expect(new Headers(init?.headers).get("atproto-proxy")).toBeNull();
      expect(body.record).toMatchObject({ text: " Thank You! ", reply: { parent: { uri: target.uri, cid }, root: (target.record as { reply: { root: unknown } }).reply.root } });
      return { uri: `at://${did}/app.bsky.feed.post/new`, cid };
    });
    await publishBrandPost({ session, text: " Thank You! ", parent: target, assertCurrentActor: () => {} });
  });
  it("resolves mentions as the brand and blocks a changed actor before writing", async () => {
    let current = true; let writes = 0;
    const session = sessionFor(path => { expect(path).toContain("com.atproto.identity.resolveHandle"); current = false; return { did: "did:plc:person" }; });
    await expect(publishBrandPost({ session, text: "Hello @person.test", assertCurrentActor: () => { if (!current) throw new Error("Changed Actor"); writes++; } })).rejects.toThrow("Changed Actor");
    expect(writes).toBe(1);
  });
  it("rejects invalid text/parent references before network traffic", async () => {
    let calls = 0;
    const session = sessionFor(() => { calls++; return {}; });
    for (const text of ["", "a".repeat(301)]) await expect(publishBrandPost({ session, text, assertCurrentActor: () => {} })).rejects.toThrow();
    await expect(publishBrandPost({ session, text: "Reply", parent: { ...target, cid: "bad" }, assertCurrentActor: () => {} })).rejects.toThrow("Target");
    expect(calls).toBe(0);
  });
});

it("publishes the selected brand's external link preview alongside its facets", async () => {
  const linkPreview = { uri: "https://example.com/story", title: "Brand Story", description: "Summary" };
  const session = sessionFor((_path, body) => {
    expect(body.repo).toBe(did);
    expect(body.record).toMatchObject({ embed: { $type: "app.bsky.embed.external", external: linkPreview }, facets: [{ features: [{ uri: linkPreview.uri }] }] });
    return { uri: `at://${did}/app.bsky.feed.post/new`, cid };
  });
  await publishBrandPost({ session, text: linkPreview.uri, linkPreview, assertCurrentActor: () => {} });
});

it("publishes brand Markdown links as native label facets", async () => {
  const session = sessionFor((path, body) => {
    expect(path).toBe("/xrpc/com.atproto.repo.createRecord");
    expect(body.record).toMatchObject({ text: "XBOX Labs", facets: [{ index: { byteStart: 0, byteEnd: 9 }, features: [{ uri: "https://labs.xbox.com/" }] }] });
    return { uri: `at://${did}/app.bsky.feed.post/one`, cid };
  });
  await publishBrandPost({ session, text: "[XBOX Labs](labs.xbox.com)", assertCurrentActor: () => {} });
});
