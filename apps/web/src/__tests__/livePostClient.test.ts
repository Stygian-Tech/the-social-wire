import { afterEach, expect, spyOn, test } from "bun:test";
import type { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import * as Atproto from "@/lib/atprotoClient";
import * as Social from "@/lib/blueskySocialClient";
import { createEvent, getEvent, listEvents, publishLiveUpdate } from "@/lib/livePosts/livePostClient";
import { appendLiveArticleContent } from "@/lib/livePosts/livePostContent";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";
const did = "did:plc:alice", session = { did } as unknown as OAuthSession;
const initial: LiveEvent = { $type: "app.thesocialwire.liveEvent", uri: `at://${did}/app.thesocialwire.liveEvent/3mf6w2zabcd22`, cid: "initial", title: "Live", destination: "bluesky", tags: ["news"], entries: [], createdAt: "2026-10-11T12:00:00.000Z", updatedAt: "2026-10-11T12:00:00.000Z" };
const op = { operationId: "operation-one", createdAt: "2026-10-11T12:01:00.000Z" };
let restore: (() => void) | undefined;
let restoreSocial: (() => void) | undefined;
afterEach(() => { restoreSocial?.(); restoreSocial = undefined; restore?.(); restore = undefined; });
function fixture(options: { ambiguous?: boolean; changed?: boolean; repeated?: boolean; blog?: boolean; host?: "offprint" | "pckt"; fresh?: boolean } = {}) {
  const publication = { uri: `at://${did}/site.standard.publication/pub`, cid: "pubcid", value: { $type: "site.standard.publication", name: "Blog", url: "https://example.com", theme: options.host ?? "markpub" } };
  const wrappers = new Map<string, { value: Record<string, unknown>; cid: string }>();
  const docs = new Map<string, { value: Record<string, unknown>; cid: string }>();
  let current = { ...initial, ...(options.blog ? { destination: "both" as const, publicationUri: publication.uri } : {}), cid: options.changed ? "changed" : initial.cid }; const batches: Record<string, unknown>[] = [];
  const getRecord = async (args: { collection: string; rkey: string }) => {
    if (args.collection === "site.standard.publication") return { data: publication };
    if (args.collection === "site.standard.document") { const doc = docs.get(args.rkey)!; return { data: { uri: `at://${did}/${args.collection}/${args.rkey}`, ...doc } }; }
    if (args.collection === "blog.pckt.publication") return { data: { uri: `at://${did}/blog.pckt.publication/pub`, cid: "nativepub", value: { publication: { uri: publication.uri, cid: publication.cid } } } };
    if (args.collection === "app.offprint.document.article" || args.collection === "blog.pckt.document") return { data: { uri: `at://${did}/${args.collection}/${args.rkey}`, ...wrappers.get(args.rkey)! } };
    if (options.fresh && !batches.length) throw Object.assign(new Error("Missing"), { error: "RecordNotFound" });
    return { data: { uri: current.uri, cid: current.cid, value: current } };
  };
  const applyWrites = async (body: { writes: { collection: string; rkey: string; value: Record<string, unknown> }[] }) => {
    batches.push(body);
    for (const write of body.writes) if (write.collection === "site.standard.document") docs.set(write.rkey, { value: write.value, cid: (await cidForLex(lexParse(JSON.stringify(write.value)))).toString() });
    for (const write of body.writes) if (write.collection === "app.offprint.document.article" || write.collection === "blog.pckt.document") wrappers.set(write.rkey, { value: write.value, cid: (await cidForLex(lexParse(JSON.stringify(write.value)))).toString() });
    const record = body.writes.at(-1)!.value;
    current = { ...record, uri: `at://${did}/app.thesocialwire.liveEvent/${body.writes.at(-1)!.rkey}`, cid: (await cidForLex(lexParse(JSON.stringify(record)))).toString() } as LiveEvent;
    if (options.ambiguous) throw new Error("Response lost"); return { data: {} };
  };
  const listRecords = async (args: { collection: string }) => args.collection === "site.standard.publication" ? { data: { records: [publication] } } : ({ data: { records: [{ uri: current.uri, cid: current.cid, value: current }], ...(options.repeated ? { cursor: "repeat" } : {}) } });
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { repo: { getRecord, applyWrites, listRecords }, sync: { getLatestCommit: async () => ({ data: { cid: "commit" } }) } } } } as unknown as Agent);
  restore = () => spy.mockRestore(); return { batches, current: () => current, docs, wrappers };
}
test("atomic post/event and operation retry do not duplicate writes", async () => {
  const f = fixture(); const event = await publishLiveUpdate(session, initial, "Hello", op);
  expect(f.batches).toHaveLength(1); expect(f.batches[0]).toMatchObject({ repo: did, swapCommit: "commit" });
  const writes = f.batches[0].writes as { collection: string; value: Record<string, unknown> }[];
  expect(writes.map(w => w.collection)).toEqual(["app.bsky.feed.post", "app.thesocialwire.liveEvent"]);
  expect(writes[0].value).toMatchObject({ text: "Live\n\nHello\n\n#news" }); expect(event.entries[0].postRef).toEqual(event.threadRoot);
  expect(await publishLiveUpdate(session, initial, "Hello", op)).toEqual(event); expect(f.batches).toHaveLength(1);
  await expect(publishLiveUpdate(session, event, "Different", op)).rejects.toThrow("different text");
});
test("replies retain original root and previous post", async () => {
  const f = fixture(); const first = await publishLiveUpdate(session, initial, "One", op);
  const next = await publishLiveUpdate(session, first, "Two", { ...op, operationId: "second" });
  expect(((f.batches[1].writes as { value: Record<string, unknown> }[])[0]).value.reply).toEqual({ root: first.threadRoot, parent: first.threadLast }); expect(next.threadRoot).toEqual(first.threadRoot);
});
test("dropped response is resolved through exact CID readback", async () => { const f = fixture({ ambiguous: true }); expect((await publishLiveUpdate(session, initial, "Hello", op)).entries).toHaveLength(1); expect(f.batches).toHaveLength(1); });
test("concurrent and cross-account mutations fail before writes", async () => {
  const f = fixture({ changed: true }); await expect(publishLiveUpdate(session, initial, "Hello", op)).rejects.toThrow("changed elsewhere");
  await expect(getEvent({ did: "did:plc:bob" } as unknown as OAuthSession, initial.uri)).rejects.toThrow("signed-in");
  await expect(publishLiveUpdate(session, initial, "Hello", { ...op, assertCurrentAccount: () => { throw new Error("switched"); } })).rejects.toThrow("switched"); expect(f.batches).toHaveLength(0);
});
test("pagination and post-length guards", async () => { const f = fixture({ repeated: true }); await expect(listEvents(session)).rejects.toThrow("repeated"); await expect(publishLiveUpdate(session, initial, "a".repeat(300), op)).rejects.toThrow("300"); expect(f.batches).toHaveLength(0); });
test("native appends preserve old blocks and refuse blob-backed rewrites", () => {
  const old = { $type: "app.offprint.content", custom: true, items: [{ $type: "app.offprint.block.image", image: { ref: "original" } }] };
  const next = appendLiveArticleContent("offprint", old, op.createdAt, "New"); expect((next.items as unknown[])[0]).toEqual(old.items[0]); expect(next.custom).toBe(true); expect(old.items).toHaveLength(1);
  expect(() => appendLiveArticleContent("markpub", { $type: "at.markpub.markdown", text: { textBlob: {} } }, op.createdAt, "New")).toThrow("Blob-backed");
});

test("both destinations and native article append commit together", async () => {
  const f = fixture({ blog: true }); const first = await publishLiveUpdate(session, f.current(), "First block", op);
  const second = await publishLiveUpdate(session, first, "Second block", { ...op, operationId: "two", createdAt: "2026-10-11T12:02:00Z" });
  const writes = f.batches[1].writes as { collection: string; value: Record<string, unknown>; $type: string }[];
  expect(writes.map(w => w.collection)).toEqual(["site.standard.document", "app.bsky.feed.post", "app.thesocialwire.liveEvent"]);
  expect(writes[0].$type).toBe("com.atproto.repo.applyWrites#update");
  const markdown = ((writes[0].value.content as Record<string, unknown>).text as Record<string, unknown>).markdown;
  expect(markdown).toBe("## 2026-10-11T12:01:00.000Z\n\nFirst block\n\n## 2026-10-11T12:02:00Z\n\nSecond block");
  expect(second.articleRef?.uri).toBe(first.articleRef?.uri); expect(second.entries).toHaveLength(2);
});

test("create retries reuse stable event identity and never publish a destination", async () => {
  const f = fixture({ fresh: true, ambiguous: true });
  const input = { title: "Event", destination: "bluesky" as const, tags: ["#news", "news"] };
  const created = await createEvent(session, input, op); const retried = await createEvent(session, input, op);
  expect(retried.uri).toBe(created.uri); expect(f.batches).toHaveLength(1); expect(created.tags).toEqual(["news"]);
  expect((f.batches[0].writes as unknown[]).length).toBe(1);
  await expect(createEvent(session, { ...input, title: "Different" }, op)).rejects.toThrow("different settings");
});
test("external article edits fail closed and produce no append or post", async () => {
  const f = fixture({ blog: true }); const event = await publishLiveUpdate(session, f.current(), "First", op);
  const doc = f.docs.values().next().value!; doc.cid = "provider-edited";
  await expect(publishLiveUpdate(session, event, "Second", { ...op, operationId: "second" })).rejects.toThrow("changed outside"); expect(f.batches).toHaveLength(1);
});
test("native updates always append literal heading/text nodes and preserve all pages", () => {
  const text = "# Not a heading\n\n![literal](article-asset://not-uploaded)";
  const old = { $type: "pub.leaflet.content", pages: [{ $type: "pub.leaflet.pages.canvas", nodes: ["original"] }, { $type: "pub.leaflet.pages.linearDocument", id: "page", blocks: [{ block: "original" }], alignment: "kept" }] };
  const result = appendLiveArticleContent("leaflet", old, op.createdAt, text);
  const pages = result.pages as { blocks: { block: { $type: string; plaintext: string } }[] }[];
  expect(pages[0] as unknown).toEqual(old.pages[0]); expect(pages[1].blocks).toHaveLength(3);
  expect(pages[1].blocks[2].block).toEqual({ $type: "pub.leaflet.blocks.text", plaintext: text });
  expect(old.pages[1].blocks).toHaveLength(1);
  for (const host of ["offprint", "pckt"] as const) { const value = appendLiveArticleContent(host, undefined, op.createdAt, text); expect((value.items as { plaintext: string }[])[1].plaintext).toBe(text); }
  expect(((appendLiveArticleContent("markpub", undefined, op.createdAt, "**Literal**").text) as { markdown: string }).markdown).toContain("\\*\\*Literal\\*\\*");
});
test("read rejects malformed destination refs, dates and mismatched record identity", async () => {
  const f = fixture();
  for (const patch of [{ createdAt: "yesterday" }, { destination: "both" }, { title: 5 }, { tags: ["😃".repeat(40)] }, { entries: [{ id: "bad", text: "text", createdAt: op.createdAt }] }]) {
    const original = { ...f.current() }; Object.assign(f.current(), patch);
    await expect(getEvent(session, initial.uri)).rejects.toThrow(); Object.assign(f.current(), original);
  }
  await expect(getEvent(session, initial.uri.replace("3mf6w2zabcd22", "other"))).rejects.toThrow("different live event");
});

test("live updates resolve mentions with native UTF8 bytes and retain atomic writes", async () => {
  const f = fixture();
  const spy = spyOn(Social, "createAuthenticatedAppViewAgent").mockReturnValue({ com: { atproto: { identity: { resolveHandle: async ({ handle }: { handle: string }) => { expect(handle).toBe("bob.test"); return { data: { did: "did:plc:bob" } }; } } } } } as unknown as Agent);
  restoreSocial = () => spy.mockRestore();
  await publishLiveUpdate(session, initial, "é @bob.test", op);
  const post = (f.batches[0].writes as { value: { facets: unknown[] } }[])[0].value;
  expect(post.facets[0]).toMatchObject({ index: { byteStart: 9, byteEnd: 18 }, features: [{ $type: "app.bsky.richtext.facet#mention", did: "did:plc:bob" }] });
  expect(f.batches).toHaveLength(1); expect(f.batches[0]).toHaveProperty("swapCommit", "commit");
});
test("failed handle resolution leaves mention text without malformed facets", async () => {
  const f = fixture();
  const spy = spyOn(Social, "createAuthenticatedAppViewAgent").mockReturnValue({ com: { atproto: { identity: { resolveHandle: async () => { throw new Error("Unknown handle"); } } } } } as unknown as Agent);
  restoreSocial = () => spy.mockRestore();
  await publishLiveUpdate(session, initial, "@missing.test", op);
  const post = (f.batches[0].writes as { value: { text: string; facets: { features: { $type: string }[] }[] } }[])[0].value;
  expect(post.text).toContain("@missing.test"); expect(post.facets.flatMap(facet => facet.features).some(feature => feature.$type === "app.bsky.richtext.facet#mention")).toBe(false);
});
test("account changes during mention lookup prevent the entire atomic commit", async () => {
  const f = fixture(); let switched = false;
  const spy = spyOn(Social, "createAuthenticatedAppViewAgent").mockReturnValue({ com: { atproto: { identity: { resolveHandle: async () => { switched = true; return { data: { did: "did:plc:bob" } }; } } } } } as unknown as Agent);
  restoreSocial = () => spy.mockRestore();
  await expect(publishLiveUpdate(session, initial, "@bob.test", { ...op, assertCurrentAccount: () => { if (switched) throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
  expect(f.batches).toHaveLength(0);
});

test("calendar prepopulation persists source identity and offset schedule on event creation", async () => {
  fixture({ fresh: true });
  const sourceEvent = { uri: "at://did:plc:bob/community.lexicon.calendar.event/source", cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" };
  const startsAt = "2026-10-12T09:00:00-05:00", endsAt = "2026-10-12T10:00:00-05:00";
  const event = await createEvent(session, { title: "Hosted", tags: [], destination: "bluesky", sourceEvent, startsAt, endsAt }, op);
  expect(event).toMatchObject({ sourceEvent, startsAt, endsAt });
  await expect(createEvent(session, { title: "Invalid", tags: [], destination: "bluesky", startsAt, endsAt: "2026-10-10T09:00:00Z" }, op)).rejects.toThrow("schedule");
});


for (const host of ["offprint", "pckt"] as const) test(`${host} live updates share canonical builders and preserve wrapper extensions`, async () => {
  const f = fixture({ blog: true, host });
  const first = await publishLiveUpdate(session, f.current(), "First", op);
  const wrapper = f.wrappers.values().next().value!;
  wrapper.value.custom = { keep: true };
  const second = await publishLiveUpdate(session, first, "Second", { ...op, operationId: "native-second", createdAt: "2026-10-11T07:02:00-05:00" });
  const writes = f.batches[1].writes as { collection: string; value: Record<string, unknown>; rkey: string }[];
  expect(writes.map(write => write.collection)).toEqual(["site.standard.document", host === "offprint" ? "app.offprint.document.article" : "blog.pckt.document", "app.bsky.feed.post", "app.thesocialwire.liveEvent"]);
  expect(writes[0].value).toMatchObject({ publishedAt: op.createdAt, updatedAt: "2026-10-11T07:02:00-05:00" });
  expect(writes[1].value).toMatchObject({ custom: { keep: true }, document: second.articleRef });
  if (host === "pckt") {
    expect(writes[1].rkey).toBe(writes[0].rkey);
    expect(writes[1].value.site).toBe(`at://${did}/blog.pckt.publication/pub`);
    expect(writes[0].value.langs).toEqual(["en"]);
  } else expect(writes[1].value.document).toHaveProperty("$type", "com.atproto.repo.strongRef");
  expect(f.batches[1]).toHaveProperty("swapCommit", "commit");
});
