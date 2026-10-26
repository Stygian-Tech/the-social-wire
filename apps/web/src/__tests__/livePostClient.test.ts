import { afterEach, expect, spyOn, test } from "bun:test";
import { jsonStringToLex, type Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import * as Atproto from "@/lib/atprotoClient";
import * as Social from "@/lib/blueskySocialClient";
import { createEvent, endLiveEvent, getEvent, listEvents, publishLiveUpdate } from "@/lib/livePosts/livePostClient";
import { appendLiveArticleContent } from "@/lib/livePosts/livePostContent";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";
import type { LiveUpdateAttachments } from "@/lib/livePosts/livePostMedia";
const did = "did:plc:alice", session = { did, getTokenInfo: async () => ({ aud: "https://pds.example" }) } as unknown as OAuthSession;
const initial: LiveEvent = { $type: "app.thesocialwire.liveEvent", uri: `at://${did}/app.thesocialwire.liveEvent/3mf6w2zabcd22`, cid: "initial", title: "Live", destination: "bluesky", tags: ["news"], entries: [], createdAt: "2026-10-11T12:00:00.000Z", updatedAt: "2026-10-11T12:00:00.000Z" };
const op = { operationId: "operation-one", createdAt: "2026-10-11T12:01:00.000Z" };
let restore: (() => void) | undefined;
let restoreSocial: (() => void) | undefined;
let restoreBitmap: (() => void) | undefined;
afterEach(() => { restoreBitmap?.(); restoreBitmap = undefined; restoreSocial?.(); restoreSocial = undefined; restore?.(); restore = undefined; });
function fixture(options: { ambiguous?: boolean; changed?: boolean; repeated?: boolean; blog?: boolean; fresh?: boolean; rejectWrite?: boolean; decoded?: boolean } = {}) {
  const publication = { uri: `at://${did}/site.standard.publication/pub`, cid: "pubcid", value: { $type: "site.standard.publication", name: "Blog", url: "https://example.com", theme: "markpub" } };
  const docs = new Map<string, { value: Record<string, unknown>; cid: string }>();
  const uploads: unknown[] = [];
  let current = { ...initial, ...(options.blog ? { destination: "both" as const, publicationUri: publication.uri } : {}), cid: options.changed ? "changed" : initial.cid }; const batches: Record<string, unknown>[] = [];
  const getRecord = async (args: { collection: string; rkey: string }) => {
    if (args.collection === "site.standard.publication") return { data: publication };
    if (args.collection === "site.standard.document") { const doc = docs.get(args.rkey)!; return { data: { uri: `at://${did}/${args.collection}/${args.rkey}`, ...doc } }; }
    if (options.fresh && !batches.length) throw Object.assign(new Error("Missing"), { error: "RecordNotFound" });
    return { data: { uri: current.uri, cid: current.cid, value: options.decoded ? jsonStringToLex(JSON.stringify(current)) : current } };
  };
  const applyWrites = async (body: { writes: { collection: string; rkey: string; value: Record<string, unknown> }[] }) => {
    batches.push(body);
    if (options.rejectWrite) throw new Error("InvalidSwap: repository changed concurrently");
    for (const write of body.writes) if (write.collection === "site.standard.document") docs.set(write.rkey, { value: write.value, cid: (await cidForLex(lexParse(JSON.stringify(write.value)))).toString() });
    const record = body.writes.at(-1)!.value;
    current = { ...record, uri: `at://${did}/app.thesocialwire.liveEvent/${body.writes.at(-1)!.rkey}`, cid: (await cidForLex(lexParse(JSON.stringify(record)))).toString() } as LiveEvent;
    if (options.ambiguous) throw new Error("Response lost"); return { data: {} };
  };
  const listRecords = async (args: { collection: string }) => args.collection === "site.standard.publication" ? { data: { records: [publication] } } : ({ data: { records: [{ uri: current.uri, cid: current.cid, value: options.decoded ? jsonStringToLex(JSON.stringify(current)) : current }], ...(options.repeated ? { cursor: "repeat" } : {}) } });
  const uploadBlob = async (body: Blob | Uint8Array, options?: { encoding?: string }) => { uploads.push(body); return { data: { blob: { $type: "blob", ref: { $link: "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" }, mimeType: body instanceof Blob ? body.type : options?.encoding, size: body instanceof Blob ? body.size : body.byteLength } } }; };
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ uploadBlob, com: { atproto: { repo: { getRecord, applyWrites, listRecords }, sync: { getLatestCommit: async () => ({ data: { cid: "commit" } }) } } } } as unknown as Agent);
  restore = () => spy.mockRestore(); return { batches, current: () => current, docs, uploads };
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

test("ending a live post persists closure and preserves content and schedule", async () => {
  const f = fixture({ blog: true });
  Object.assign(f.current(), { startsAt: "2026-10-11T11:00:00Z", endsAt: "2026-10-11T13:00:00Z" });
  const published = await publishLiveUpdate(session, f.current(), "Last update", op);
  const ended = await endLiveEvent(session, published);
  expect(ended.endedAt).toBe(ended.updatedAt); expect(Number.isFinite(Date.parse(ended.endedAt!))).toBe(true);
  expect(ended).toMatchObject({ ...published, cid: ended.cid, updatedAt: ended.updatedAt, endedAt: ended.endedAt });
  expect(f.batches).toHaveLength(2);
  expect(f.batches[1]).toMatchObject({ repo: did, swapCommit: "commit", writes: [{ $type: "com.atproto.repo.applyWrites#update", collection: "app.thesocialwire.liveEvent", value: { endedAt: ended.endedAt, entries: published.entries, articleRef: published.articleRef, threadRoot: published.threadRoot } }] });
  expect((f.batches[1].writes as unknown[])).toHaveLength(1);
  expect(await getEvent(session, ended.uri)).toEqual(ended);
  expect(await endLiveEvent(session, published)).toEqual(ended); expect(f.batches).toHaveLength(2);
  await expect(publishLiveUpdate(session, published, "More", { ...op, operationId: "new" })).rejects.toThrow("has ended");
  expect(await publishLiveUpdate(session, published, "Last update", op)).toEqual(ended); expect(f.batches).toHaveLength(2);
});

test("scheduled end alone leaves a live post open", async () => {
  const f = fixture(); Object.assign(f.current(), { endsAt: "2020-01-01T12:00:00Z" });
  expect((await publishLiveUpdate(session, f.current(), "Still live", op)).entries).toHaveLength(1);
});

test("end rejects stale sessions and wrong owners without writing", async () => {
  const f = fixture({ changed: true });
  await expect(endLiveEvent(session, initial)).rejects.toThrow("changed elsewhere");
  await expect(endLiveEvent({ did: "did:plc:bob" } as unknown as OAuthSession, initial)).rejects.toThrow("signed-in");
  await expect(endLiveEvent(session, initial, { assertCurrentAccount: () => { throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
  const controller = new AbortController(); controller.abort();
  await expect(endLiveEvent(session, initial, { signal: controller.signal })).rejects.toThrow();
  expect(f.batches).toHaveLength(0);
});

test("end uses repo CAS and does not blindly retry a concurrent write failure", async () => {
  const f = fixture({ rejectWrite: true });
  await expect(endLiveEvent(session, initial)).rejects.toThrow("InvalidSwap");
  expect(f.batches).toHaveLength(1); expect(f.batches[0]).toHaveProperty("swapCommit", "commit"); expect(f.current().endedAt).toBeUndefined();
});

test("end reconciles dropped write responses and retries without duplicate writes", async () => {
  const f = fixture({ ambiguous: true }); const ended = await endLiveEvent(session, initial);
  expect(ended.endedAt).toBeDefined(); expect(await endLiveEvent(session, initial)).toEqual(ended); expect(f.batches).toHaveLength(1);
});

test("end checks account ownership again after loading the fresh session", async () => {
  const f = fixture(); let checks = 0;
  await expect(endLiveEvent(session, initial, { assertCurrentAccount: () => { if (++checks === 2) throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
  expect(f.batches).toHaveLength(0);
});

test("live post reads reject malformed closure timestamps", async () => {
  const f = fixture(); Object.assign(f.current(), { endedAt: "yesterday" });
  await expect(getEvent(session, initial.uri)).rejects.toThrow("end time");
});

test("media publishes atomically and stable retries compare attachment bytes and alt text", async () => {
  const f = fixture({ decoded: true });
  const originalBitmap = Object.getOwnPropertyDescriptor(globalThis, "createImageBitmap");
  Object.defineProperty(globalThis, "createImageBitmap", { configurable: true, value: async () => ({ width: 640, height: 480, close() {} }) });
  restoreBitmap = () => { if (originalBitmap) Object.defineProperty(globalThis, "createImageBitmap", originalBitmap); else Reflect.deleteProperty(globalThis, "createImageBitmap"); };
  const attachments: LiveUpdateAttachments = { images: [{ file: new Blob(["first image"], { type: "image/png" }), alt: "View from the event" }] };
  const event = await publishLiveUpdate(session, initial, "", op, attachments);
  expect(f.uploads).toHaveLength(1); expect(f.batches).toHaveLength(1);
  expect(event.entries[0]).toMatchObject({ media: { images: [{ alt: "View from the event", blob: { mimeType: "image/png" } }] } });
  const writes = f.batches[0].writes as { value: Record<string, unknown> }[];
  expect(writes[0].value.embed).toMatchObject({ $type: "app.bsky.embed.images", images: [{ alt: "View from the event" }] });
  const loaded = await getEvent(session, event.uri);
  expect(loaded).toEqual(event);
  expect(loaded.entries[0].media?.images?.[0].blob.ref.$link).toBe("bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku");
  expect((await listEvents(session))[0]).toEqual(event);
  expect(await publishLiveUpdate(session, initial, "", op, attachments)).toEqual(event);
  expect(f.uploads).toHaveLength(1); expect(f.batches).toHaveLength(1);
  for (const changed of [{ images: [{ ...attachments.images![0], alt: "Different" }] }, { images: [{ ...attachments.images![0], file: new Blob(["other bytes"], { type: "image/png" }) }] }, undefined]) {
    await expect(publishLiveUpdate(session, event, changed ? "" : "Photo update", op, changed)).rejects.toThrow(changed ? "different media" : "different text");
  }
  expect(f.uploads).toHaveLength(1); expect(f.batches).toHaveLength(1);
});

test("ambiguous media write reconciles without uploading or posting duplicates", async () => {
  const f = fixture({ ambiguous: true });
  const attachments: LiveUpdateAttachments = { gif: { url: "https://media.example.com/celebration.gif", alt: "Celebration" } };
  const event = await publishLiveUpdate(session, initial, "GIF update", op, attachments);
  expect(await publishLiveUpdate(session, initial, "GIF update", op, attachments)).toEqual(event);
  expect(f.batches).toHaveLength(1); expect(event.entries[0].media?.gif).toEqual(attachments.gif);
});

test("live session reads reject malformed persisted media", async () => {
  const f = fixture(); const event = await publishLiveUpdate(session, initial, "Hello", op);
  Object.assign(f.current().entries[0], { media: { images: [{ alt: "Invalid", blob: { $type: "blob", mimeType: "image/png", size: 10, ref: { $link: "invalid" } } }] } });
  await expect(getEvent(session, event.uri)).rejects.toThrow();
});
