import { expect, it } from "bun:test";
import { AppBskyFeedPost } from "@atproto/api";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { newThreadPublication, publishBlueskyThread } from "@/lib/blueskyThreadClient";

const did = "did:plc:alice";
function pds(handler: (method: string, body: Record<string, unknown> | undefined, query: URLSearchParams) => Promise<unknown> | unknown) {
  return { did, fetchHandler: async (path: string, init?: RequestInit) => {
    const url = new URL(path, "https://pds.example");
    const body = init?.body ? await new Response(init.body).json() : undefined;
    const result = await handler(url.pathname.split("/").at(-1)!, body, url.searchParams);
    return result instanceof Response ? result : Response.json(result);
  } } as unknown as OAuthSession;
}
const draft = () => [{ id: "a", text: "First #one" }, { id: "b", text: "Second https://example.com" }, { id: "c", text: "Third #three" }];
async function reference(rkey: string, record: unknown) {
  return { uri: `at://${did}/app.bsky.feed.post/${rkey}`, cid: (await cidForLex(lexParse(JSON.stringify(record), { strict: true }))).toString() };
}
it("validates every segment before writes and assigns stable native record keys", () => {
  expect(() => newThreadPublication(did, [...draft(), { id: "bad", text: "" }])).toThrow();
  expect(() => newThreadPublication(did, [{ id: "bad", text: "👩‍👩‍👧‍👦".repeat(300) }])).toThrow();
  const publication = newThreadPublication(did, draft());
  expect(new Set(publication.segments.map(segment => segment.rkey)).size).toBe(3);
  for (const segment of publication.segments) expect(segment.rkey).toMatch(/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/);
});
it("posts sequential native replies with independent facets and root ancestry", async () => {
  const writes: Record<string, unknown>[] = [];
  const results: { uri: string; cid: string }[] = [];
  const session = pds(async (method, body) => {
    expect(method).toBe("com.atproto.repo.createRecord");
    const record = body!.record as AppBskyFeedPost.Record;
    expect(AppBskyFeedPost.validateRecord(record).success).toBe(true);
    writes.push(body!);
    if (results.length) expect(record.reply).toEqual({ root: results[0], parent: results.at(-1)! });
    else expect(record.reply).toBeUndefined();
    const result = await reference(body!.rkey as string, record);
    results.push(result);
    return result;
  });
  const progress: number[] = [];
  const publication = newThreadPublication(did, draft());
  expect(await publishBlueskyThread({ session, publication, assertCurrentAccount: () => {}, onProgress: completed => progress.push(completed) })).toEqual(results);
  expect(progress).toEqual([1, 2, 3]);
  expect((writes[0].record as AppBskyFeedPost.Record).facets![0].features[0]).toMatchObject({ tag: "one" });
  expect((writes[1].record as AppBskyFeedPost.Record).facets![0].features[0]).toMatchObject({ uri: "https://example.com" });
});
it("reconciles an ambiguous committed write on retry without duplicating posts", async () => {
  const records = new Map<string, { uri: string; cid: string; value: unknown }>();
  let fail = true;
  let writes = 0;
  const session = pds(async (method, body, query) => {
    if (method.endsWith("getRecord")) return records.get(query.get("rkey")!);
    writes++;
    const record = body!.record;
    const result = await reference(body!.rkey as string, record);
    records.set(body!.rkey as string, { ...result, value: record });
    if (records.size === 2 && fail) { fail = false; throw new Error("Connection Lost After Commit"); }
    return result;
  });
  const publication = newThreadPublication(did, draft());
  await expect(publishBlueskyThread({ session, publication, assertCurrentAccount: () => {} })).rejects.toThrow();
  expect(publication.segments.filter(segment => segment.result)).toHaveLength(1);
  await publishBlueskyThread({ session, publication, assertCurrentAccount: () => {} });
  expect(writes).toBe(3);
  expect(records.size).toBe(3);
});
it("retries the same key only after confirmed absence and stops on lookup failure", async () => {
  const publication = newThreadPublication(did, draft());
  let reads = 0;
  let writes = 0;
  const session = pds(async (method, body) => {
    if (method.endsWith("getRecord")) {
      reads++;
      if (reads === 1) return Response.json({ error: "Unavailable" }, { status: 503 });
      return Response.json({ error: "RecordNotFound" }, { status: 400 });
    }
    writes++;
    if (writes === 1) throw new Error("Failed Before Commit");
    return reference(body!.rkey as string, body!.record);
  });
  await expect(publishBlueskyThread({ session, publication, assertCurrentAccount: () => {} })).rejects.toThrow();
  await expect(publishBlueskyThread({ session, publication, assertCurrentAccount: () => {} })).rejects.toThrow();
  expect(writes).toBe(1);
  await publishBlueskyThread({ session, publication, assertCurrentAccount: () => {} });
  expect(writes).toBe(4);
});
it("fails closed if a previously attempted record was changed", async () => {
  const publication = newThreadPublication(did, draft());
  let writes = 0;
  const session = pds(method => {
    if (method.endsWith("getRecord")) return { uri: `at://${did}/app.bsky.feed.post/${publication.segments[0].rkey}`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", value: {} };
    writes++;
    throw new Error("Ambiguous Failure");
  });
  await expect(publishBlueskyThread({ session, publication, assertCurrentAccount: () => {} })).rejects.toThrow();
  await expect(publishBlueskyThread({ session, publication, assertCurrentAccount: () => {} })).rejects.toThrow("Changed on Your PDS");
  expect(writes).toBe(1);
});
it("guards account identity before resolving or writing a thread", async () => {
  let calls = 0;
  const session = pds(() => { calls++; return {}; });
  const publication = newThreadPublication(did, draft());
  await expect(publishBlueskyThread({ session, publication, assertCurrentAccount: () => { throw new Error("Account Changed"); } })).rejects.toThrow();
  await expect(publishBlueskyThread({ session, publication: { ...publication, did: "did:plc:other" }, assertCurrentAccount: () => {} })).rejects.toThrow();
  expect(calls).toBe(0);
});
