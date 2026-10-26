import { afterEach, expect, spyOn, test } from "bun:test";
import type { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Atproto from "@/lib/atprotoClient";
import * as Network from "@/lib/atprotoNetwork";
import { listViewerAtmoEvents, liveEventPhase, parseAtmoEvent } from "@/lib/livePosts/atmoEventClient";
const did = "did:plc:alice", bob = "did:plc:bob", collection = "community.lexicon.calendar.event", rsvp = "community.lexicon.calendar.rsvp";
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", session = { did } as unknown as OAuthSession;
const event = (actor: string, key: string, status?: string) => ({ uri: `at://${actor}/${collection}/${key}`, cid, value: { $type: collection, name: key, createdAt: "2026-10-11T12:00:00Z", startsAt: "2026-10-12T09:00:00-05:00", endsAt: "2026-10-12T10:00:00-05:00", ...(status ? { status } : {}) } });
const restores: (() => void)[] = [];
const mockFetch = (fn: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>): typeof fetch => Object.assign(fn, { preconnect: globalThis.fetch.preconnect });
const oldAllowed = process.env.NEXT_PUBLIC_LOCAL_ATPROTO_CALENDAR_PDS_URLS;
afterEach(() => { if (oldAllowed === undefined) delete process.env.NEXT_PUBLIC_LOCAL_ATPROTO_CALENDAR_PDS_URLS; else process.env.NEXT_PUBLIC_LOCAL_ATPROTO_CALENDAR_PDS_URLS = oldAllowed; while (restores.length) restores.pop()!(); });
function fakePDS(records: { uri: string; cid: string; value: unknown }[], rsvps: unknown[] = [], repeat = false) {
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { repo: { listRecords: async (args: { repo: string; collection: string }) => { expect(args.repo).toBe(did); return { data: { records: args.collection === collection ? records : rsvps, ...(repeat ? { cursor: "same" } : {}) } }; } } } } } as unknown as Agent);
  restores.push(() => spy.mockRestore());
}
test("personal discovery includes hosted events and going/interested only, without credentials on foreign PDS", async () => {
  process.env.NEXT_PUBLIC_LOCAL_ATPROTO_CALENDAR_PDS_URLS = "https://pds2.atmosbox.test";
  const other = event(bob, "going"), interest = event(bob, "interest");
  fakePDS([event(did, "hosted"), event(did, "cancelled", `${collection}#cancelled`)], [other, interest, event(bob, "declined")].map((record, i) => ({ uri: `at://${did}/${rsvp}/${i}`, cid, value: { $type: rsvp, status: `${rsvp}#${["going", "interested", "notgoing"][i]}`, subject: { uri: record.uri, cid } } })));
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ plcDirectory: "https://plc.atmosbox.test", publicAppView: "https://appview.atmosbox.test", handleResolver: "https://appview.atmosbox.test", appViewDid: "did:web:appview.atmosbox.test" }); restores.push(() => network.mockRestore());
  const requests: string[] = [];
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(mockFetch(async (input, init) => {
    const url = String(input); requests.push(url); expect(init?.credentials).toBe("omit"); expect(new Headers(init?.headers).has("Authorization")).toBe(false); expect(new Headers(init?.headers).has("DPoP")).toBe(false);
    if (url.startsWith("https://plc.atmosbox.test/")) return Response.json({ id: bob, service: [{ id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://pds2.atmosbox.test" }] });
    const key = new URL(url).searchParams.get("rkey"); return Response.json(key === "going" ? other : interest);
  })); restores.push(() => fetchSpy.mockRestore());
  const events = await listViewerAtmoEvents(session);
  expect(events.map(e => e.title)).toEqual(["hosted", "going", "interest"]); expect(events[0].startsAt).toBe("2026-10-12T09:00:00-05:00"); expect(events[1].url).toBe("https://atmo.rsvp/p/did%3Aplc%3Abob/e/going");
  expect(requests.every(url => url.includes("atmosbox.test"))).toBe(true); expect(requests.some(url => url.includes("declined"))).toBe(false);
});
test("grouping uses exact time boundaries and atmo start-only semantics", () => {
  const now = Date.parse("2026-10-12T14:00:00Z");
  expect(liveEventPhase({ startsAt: "2026-10-12T09:00:00-05:00", endsAt: "2026-10-12T10:00:00-05:00" }, now)).toBe("current");
  expect(liveEventPhase({ startsAt: "2026-10-12T09:01:00-05:00" }, now)).toBe("upcoming");
  expect(liveEventPhase({ startsAt: "2026-10-12T09:00:00-05:00" }, now)).toBe("past");
  expect(liveEventPhase({ endsAt: "2026-10-12T14:00:00Z" }, now)).toBe("past"); expect(liveEventPhase({}, now)).toBe("current");
});
test("invalid calendar times/identity and repeated account pagination fail", async () => {
  const valid = event(did, "event");
  expect(() => parseAtmoEvent({ ...valid, value: { ...valid.value, startsAt: "2026-10-12T10:00:00", endsAt: "bad" } })).toThrow();
  expect(() => parseAtmoEvent({ ...valid, uri: "https://example.com" })).toThrow();
  fakePDS([valid], [], true); await expect(listViewerAtmoEvents(session)).rejects.toThrow("repeated");
});

test("isolated local PLC never allows unlisted public PDS egress", async () => {
  const subject = event(bob, "going"); fakePDS([], [{ uri: `at://${did}/${rsvp}/one`, cid, value: { $type: rsvp, status: `${rsvp}#going`, subject: { uri: subject.uri, cid } } }]);
  process.env.NEXT_PUBLIC_LOCAL_ATPROTO_CALENDAR_PDS_URLS = "https://pds1.atmosbox.test,https://pds2.atmosbox.test";
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ plcDirectory: "https://plc.atmosbox.test", publicAppView: "https://appview.atmosbox.test", handleResolver: "https://appview.atmosbox.test", appViewDid: "did:web:appview.atmosbox.test" }); restores.push(() => network.mockRestore());
  let calls = 0; const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(mockFetch(async (input) => { calls++; expect(String(input)).toStartWith("https://plc.atmosbox.test/"); return Response.json({ id: bob, service: [{ id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://public-pds.example" }] }); })); restores.push(() => fetchSpy.mockRestore());
  await expect(listViewerAtmoEvents(session)).rejects.toThrow("not allowed"); expect(calls).toBe(1);
});
test("contradictory RSVP statuses are rejected independently of pagination order", async () => {
  const subject = { uri: event(bob, "one").uri, cid };
  fakePDS([], ["going", "notgoing"].map((status, i) => ({ uri: `at://${did}/${rsvp}/${i}`, cid, value: { $type: rsvp, subject, status: `${rsvp}#${status}` } })));
  await expect(listViewerAtmoEvents(session)).rejects.toThrow("Conflicting RSVP");
});

test("events sort by actual instants across timezone offsets", async () => {
  const earlier = event(did, "earlier"), later = event(did, "later"); earlier.value.startsAt = "2026-10-12T10:00:00Z"; earlier.value.endsAt = "2026-10-12T11:00:00Z"; later.value.startsAt = "2026-10-12T09:00:00-05:00";
  fakePDS([later, earlier]); expect((await listViewerAtmoEvents(session)).map(e => e.title)).toEqual(["earlier", "later"]);
});
test("deleted RSVP subjects skip without hiding hosted events; auth failures remain visible", async () => {
  const subject = { uri: event(bob, "deleted").uri, cid }; fakePDS([event(did, "hosted")], [{ uri: `at://${did}/${rsvp}/one`, cid, value: { $type: rsvp, subject, status: `${rsvp}#going` } }]);
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ plcDirectory: "https://plc.directory", publicAppView: "https://public.api.bsky.app", handleResolver: "https://public.api.bsky.app", appViewDid: "did:web:api.bsky.app" }); restores.push(() => network.mockRestore());
  let status = 404;
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(mockFetch(async (input) => String(input).includes("plc.directory") ? Response.json({ id: bob, service: [{ id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://bob.pds.example" }] }) : Response.json({ error: status === 404 ? "RecordNotFound" : "AuthRequired" }, { status }))); restores.push(() => fetchSpy.mockRestore());
  expect((await listViewerAtmoEvents(session)).map(e => e.title)).toEqual(["hosted"]);
  status = 403; await expect(listViewerAtmoEvents(session)).rejects.toThrow("403");
});


test("explicitly ended sessions group as past regardless of their calendar schedule", () => {
  const endedAt = "2026-10-26T22:00:00Z";
  expect(liveEventPhase({ endedAt })).toBe("past");
  expect(liveEventPhase({ startsAt: "2100-01-01T00:00:00Z", endsAt: "2100-01-02T00:00:00Z", endedAt })).toBe("past");
});

function articleMirror(key: string) {
  return { uri: `at://${did}/${collection}/${key}`, cid, value: { $type: collection, name: key, createdAt: "2026-08-12T22:02:07Z", startsAt: "2026-08-12T22:02:07Z", mode: `${collection}#virtual`, status: `${collection}#scheduled`, description: "A published article", uris: [{ name: "Article URL", uri: `https://blog.test/${key}` }, { name: "ATProto record", uri: `at://${did}/site.standard.document/${key}` }] } };
}

test("discovery excludes legacy article mirrors shown in the annotated event list", async () => {
  const titles = ["First Offprint Test", "Another Article", "This Is Another One", "Creating Another Test Document", "Testing Leaflet", "Another pckt Test"];
  const mirrors = titles.map((title, index) => { const record = articleMirror(`article-${index}`); record.value.name = title; return record; });
  const scheduled = articleMirror("scheduled-article"); scheduled.value.startsAt = "2100-01-01T00:00:00Z";
  const conference = event(did, "real-conference"); conference.value.name = "Real Conference";
  fakePDS([...mirrors, scheduled, conference]);
  const before = JSON.stringify(mirrors);
  expect((await listViewerAtmoEvents(session)).map(row => row.title)).toEqual(["Real Conference"]);
  expect(JSON.stringify(mirrors)).toBe(before);
});

test("preserves genuine start-only events and events with companion articles or calendar metadata", async () => {
  const base = articleMirror("companion");
  const startOnly = { ...event(did, "start-only"), value: { $type: collection, name: "Start Only", createdAt: base.value.createdAt, startsAt: base.value.startsAt, mode: `${collection}#virtual`, status: `${collection}#scheduled` } };
  const candidates = [
    startOnly,
    { ...base, uri: `${base.uri}-end`, value: { ...base.value, endsAt: "2026-08-12T23:02:07Z" } },
    { ...base, uri: `${base.uri}-client`, value: { ...base.value, createdWith: "https://atmo.rsvp" } },
    { ...base, uri: `${base.uri}-venue`, value: { ...base.value, locations: [{ name: "Conference Hall" }] } },
    { ...base, uri: `${base.uri}-stream`, value: { ...base.value, uris: [...base.value.uris, { name: "Stream", uri: "https://stream.place/conference" }] } },
    { ...base, uri: `${base.uri}-article-link`, value: { ...base.value, uris: [base.value.uris[0]] } },
  ];
  fakePDS(candidates);
  expect((await listViewerAtmoEvents(session)).map(row => row.uri).sort()).toEqual(candidates.map(row => row.uri).sort());
});

test("article mirror exclusion applies to RSVP subjects", async () => {
  const mirror = articleMirror("rsvp-article");
  fakePDS([], [{ uri: `at://${did}/${rsvp}/one`, cid, value: { $type: rsvp, status: `${rsvp}#interested`, subject: { uri: mirror.uri, cid } } }]);
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ plcDirectory: "https://plc.directory", publicAppView: "https://public.api.bsky.app", handleResolver: "https://public.api.bsky.app", appViewDid: "did:web:api.bsky.app" }); restores.push(() => network.mockRestore());
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(mockFetch(async input => String(input).includes("plc.directory") ? Response.json({ id: did, service: [{ id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: "https://alice.pds.example" }] }) : Response.json(mirror))); restores.push(() => fetchSpy.mockRestore());
  expect(await listViewerAtmoEvents(session)).toEqual([]);
});

test("malformed calendar data still fails validation when it resembles an article mirror", async () => {
  const malformed = articleMirror("malformed"); malformed.value.createdAt = "yesterday";
  fakePDS([malformed]);
  await expect(listViewerAtmoEvents(session)).rejects.toThrow("Invalid atmo.rsvp calendar event");
});
