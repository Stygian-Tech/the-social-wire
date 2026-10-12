import { afterEach, expect, spyOn, test } from "bun:test";
import type { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import * as Atproto from "@/lib/atprotoClient";
import { endLivestream, generateStreamKey, getStreamIngests, saveLivestream, sendStreamChat, uploadStreamThumbnail } from "@/lib/livestream/streamplaceClient";
import { streamplaceNodeOrigin } from "@/lib/livestream/streamplaceNode";
import { reduceStreamSnapshot } from "@/lib/livestream/streamplaceRealtime";
import type { Livestream, StreamSnapshot } from "@/lib/livestream/livestreamTypes";
const session = { did: "did:plc:alice" } as unknown as OAuthSession, node = "https://stream.place", operation = { rkey: "3mf6w2zabcd22", createdAt: "2026-10-11T12:00:00Z" };
const restores: (() => void)[] = [];
afterEach(() => { while (restores.length) restores.pop()!(); });
function pds(ambiguous = false, lostReadbacks = 0) {
  const writes: { collection: string; value: Record<string, unknown> }[] = []; let saved: Livestream | undefined;
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { sync: { getLatestCommit: async () => ({ data: { cid: "commit" } }) }, repo: {
    listRecords: async () => ({ data: { records: saved ? [{ uri: saved.uri, cid: saved.cid, value: saved.record }] : [] } }),
    getRecord: async () => { if (lostReadbacks-- > 0) throw new Error("Readback Lost"); return { data: { ...saved, value: saved?.record } }; },
    applyWrites: async (input: { repo: string; swapCommit: string; writes: { collection: string; rkey: string; value: Record<string, unknown> }[] }) => { expect(input.repo).toBe(session.did); expect(input.swapCommit).toBe("commit"); writes.push(...input.writes); const write = input.writes[0]; saved = { uri: `at://${session.did}/${write.collection}/${write.rkey}`, cid: (await cidForLex(lexParse(JSON.stringify(write.value)))).toString(), record: write.value as Livestream["record"] }; if (ambiguous) throw new Error("Response Lost"); return { data: {} }; },
  } } } } as unknown as Agent); restores.push(() => spy.mockRestore()); return { writes, get saved() { return saved; } };
}
test("node origins exclude private hosts, credentials, path redirects and HTTP", () => {
  for (const url of ["http://stream.place", "https://localhost", "https://127.0.0.1", "https://[::1]", "https://example.test", "https://user:secret@stream.place", "https://stream.place/path", "https://stream.place/?key=x"]) expect(() => streamplaceNodeOrigin(url)).toThrow();
  expect(streamplaceNodeOrigin("https://custom.example.com/")).toBe("https://custom.example.com");
});
test("public ingest discovery sends no OAuth or cookies", async () => {
  const fetcher = Object.assign(async (input: RequestInfo | URL, init?: RequestInit) => { expect(String(input)).toBe(`${node}/xrpc/place.stream.ingest.getIngestUrls`); expect(init?.credentials).toBe("omit"); expect(new Headers(init?.headers).get("Authorization")).toBeNull(); return Response.json({ ingests: [{ type: "rtmps", url: "rtmps://rtmp.stream.place:1935/live" }] }); }, { preconnect: fetch.preconnect });
  const spy = spyOn(globalThis, "fetch").mockImplementation(fetcher); restores.push(() => spy.mockRestore()); expect(await getStreamIngests(node)).toHaveLength(1);
});
test("stream key publishes only public signing identity, never OBS secret", async () => {
  const f = pds(); const result = await generateStreamKey(session, operation);
  expect(result.secret.startsWith("z")).toBe(true); expect(result.signingKey.startsWith("did:key:z")).toBe(true);
  expect(f.writes[0].collection).toBe("place.stream.key"); expect(Object.keys(f.writes[0].value)).toEqual(["$type", "signingKey", "createdAt", "createdBy"]);
  expect(JSON.stringify(f.writes).includes(result.secret)).toBe(false);
});
test("metadata create/update/end preserve identity and recover lost responses", async () => {
  const f = pds(true); const first = await saveLivestream(session, node, { title: "Live", tags: ["tech"] }, operation);
  const next = await saveLivestream(session, node, { title: "Updated", tags: [] }, operation, first);
  expect(next.uri).toBe(first.uri); expect(next.record.createdAt).toBe(operation.createdAt);
  const ended = await endLivestream(session, next, { ...operation, createdAt: "2026-10-11T13:00:00Z" }); expect(ended.record.endedAt).toBe("2026-10-11T13:00:00Z"); expect(f.writes).toHaveLength(3);
  await expect(saveLivestream(session, node, { title: "Restart", tags: [] }, operation, ended)).rejects.toThrow("Ended");
});
test("identity, content and thumbnail validation happen before PDS writes", async () => {
  const f = pds(); await expect(generateStreamKey(session, { ...operation, assertCurrentAccount: () => { throw new Error("Changed"); } })).rejects.toThrow("Changed");
  await expect(saveLivestream(session, node, { title: "x".repeat(141), tags: [] }, operation)).rejects.toThrow("140");
  await expect(saveLivestream(session, node, { title: "Live", tags: ["bad tag"] }, operation)).rejects.toThrow("alphanumeric");
  await expect(uploadStreamThumbnail(session, new Blob(["video"], { type: "video/mp4" }), () => {})).rejects.toThrow("image"); expect(f.writes).toHaveLength(0);
});
test("chat writes viewer-owned public message with stable identity", async () => { const f = pds(); await sendStreamChat(session, session.did, "Hello", operation); expect(f.writes[0]).toMatchObject({ collection: "place.stream.chat.message", value: { text: "Hello", streamer: session.did } }); await expect(sendStreamChat(session, session.did, "x".repeat(301), operation)).rejects.toThrow("300"); });
test("realtime deduplicates bounded chat and distinguishes absent session totals", () => {
  const base: StreamSnapshot = { messages: [], connected: true }; const item = { $type: "place.stream.chat.defs#messageView", uri: `at://${session.did}/place.stream.chat.message/msg`, cid: "cid", author: { did: session.did, handle: "alice.test" }, record: { $type: "place.stream.chat.message", text: "Hello", streamer: session.did, createdAt: operation.createdAt } };
  const result = reduceStreamSnapshot(base, [item, item, { $type: "place.stream.livestream#viewerCount", count: 2, total: 5 }], session.did); expect(result.messages).toHaveLength(1); expect(result.viewers).toBe(2); expect(result.totalSessions).toBe(5);
  expect(reduceStreamSnapshot(result, { $type: "place.stream.livestream#viewerCount", count: 1 }, session.did).totalSessions).toBeUndefined();
  expect(reduceStreamSnapshot(base, { ...item, record: { ...item.record, streamer: "did:plc:other" } }, session.did).messages).toHaveLength(0);
});

test("announcement retry adopts its exact committed record without a second write", async () => {
  const f = pds(true, 1);
  await expect(saveLivestream(session, node, { title: "Live", tags: [] }, operation)).rejects.toThrow("Response Lost");
  const result = await saveLivestream(session, node, { title: "Live", tags: [] }, operation);
  expect(result.cid).toBe(f.saved!.cid); expect(f.writes).toHaveLength(1);
  await expect(saveLivestream(session, node, { title: "Divergent", tags: [] }, operation)).rejects.toThrow("Changed Elsewhere");
  await expect(saveLivestream(session, node, { title: "Second", tags: [] }, { ...operation, rkey: "3mf6w2zabcd23" })).rejects.toThrow("End Your Current");
});
test("metadata update retry adopts exact new CID after a lost write response", async () => {
  const f = pds(true);
  const first = await saveLivestream(session, node, { title: "Live", tags: [] }, operation);
  const next = await saveLivestream(session, node, { title: "Updated", tags: [] }, operation, first);
  const retry = await saveLivestream(session, node, { title: "Updated", tags: [] }, operation, first);
  expect(retry.cid).toBe(next.cid); expect(f.writes).toHaveLength(2);
});
test("ingest type must match the advertised protocol", async () => {
  const fetcher = Object.assign(async () => Response.json({ ingests: [{ type: "rtmps", url: "https://stream.place" }] }), { preconnect: fetch.preconnect });
  const spy = spyOn(globalThis, "fetch").mockImplementation(fetcher); restores.push(() => spy.mockRestore());
  await expect(getStreamIngests(node)).rejects.toThrow("unsafe ingest");
});
