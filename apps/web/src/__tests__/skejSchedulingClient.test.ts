import { afterEach, expect, spyOn, test } from "bun:test";
import type { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Atproto from "@/lib/atprotoClient";
import * as Social from "@/lib/blueskySocialClient";
import * as Environment from "@/lib/skej/skejEnvironment";
import { cancelSkejSchedule, createSkejSchedule, getSkejSchedulingReadiness, listSkejSchedules, rescheduleSkejPost, SkejSchedulingError, type SkejScheduleRecord, type SkejScheduleSummary } from "@/lib/skej/skejSchedulingClient";

const did = "did:plc:brand", session = { did } as unknown as OAuthSession;
const future = "2099-01-01T12:00:00.000Z";
const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });
function item(): SkejScheduleSummary {
  return { did, rkey: "schedule-one", scheduleUri: `at://${did}/at.skej.schedule/schedule-one`, scheduledAt: future, status: "scheduled", attempts: 0, record: { $type: "at.skej.schedule", scheduledAt: future, status: "scheduled", createdAt: "2026-10-11T12:00:00Z", updatedAt: "2026-10-11T12:00:00Z", timezonePolicy: "absolute_utc", recordType: "app.bsky.feed.post", publishRkey: "stable-post", retry: { attemptCount: 0, maxAttempts: 8 }, posts: [{ text: "Scheduled", publishRkey: "stable-post" }] } };
}
function fixture(options: { status?: number; body?: unknown; afterMint?: () => void } = {}) {
  const mints: { aud: string; lxm: string; exp: number }[] = [];
  const requests: { url: URL; init: RequestInit; payload?: Record<string, unknown> }[] = [];
  const agent = { com: { atproto: { server: { getServiceAuth: async (input: { aud: string; lxm: string; exp: number }) => { mints.push(input); options.afterMint?.(); return { data: { token: "one-method-grant" } }; } } } } } as unknown as Agent;
  const oauth = spyOn(Atproto, "createOAuthAgent").mockImplementation(actor => { expect(actor).toBe(session); return agent; });
  const appview = spyOn(Social, "createAuthenticatedAppViewAgent").mockReturnValue({} as Agent);
  const env = spyOn(Environment, "getSkejEnvironment").mockReturnValue({ api: "https://scheduler.example", audience: "did:web:scheduler.example#skej_scheduler", connectUrl: "https://scheduler.example/oauth/start" });
  const fetcher = spyOn(globalThis, "fetch").mockImplementation((async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input)); const payload = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : undefined;
    requests.push({ url, init: init!, payload });
    const body = options.body ?? (payload?.record ? { ...item(), record: payload.record, scheduledAt: (payload.record as SkejScheduleRecord).scheduledAt } : url.pathname.endsWith("getSession") ? { did } : url.pathname.endsWith("list") ? { records: [item()] } : item());
    return Response.json(body, { status: options.status ?? 200 });
  }) as typeof fetch);
  cleanups.push(() => oauth.mockRestore(), () => appview.mockRestore(), () => env.mockRestore(), () => fetcher.mockRestore());
  return { mints, requests, actor: { session, assertCurrentActor: () => {} } };
}

test("service authorization uses the selected actor, exact audience and method with a short expiry", async () => {
  const f = fixture(), before = Math.floor(Date.now() / 1000);
  await listSkejSchedules(f.actor);
  expect(f.mints).toHaveLength(1);
  expect(f.mints[0]).toMatchObject({ aud: "did:web:scheduler.example#skej_scheduler", lxm: "at.skej.schedule.list" });
  expect(f.mints[0].exp).toBeGreaterThanOrEqual(before + 60);
  expect(f.mints[0].exp).toBeLessThanOrEqual(Math.floor(Date.now() / 1000) + 60);
  expect(f.requests[0].url.searchParams.get("accountDid")).toBe(did);
  expect(f.requests[0].init).toMatchObject({ method: "GET", credentials: "omit", redirect: "error", headers: { Authorization: "Bearer one-method-grant" } });
});

test("AccountNeedsReauth is a disconnected readiness result and a typed mutation failure", async () => {
  const f = fixture({ status: 403, body: { error: "AccountNeedsReauth", message: "private provider detail" } });
  expect(await getSkejSchedulingReadiness(f.actor)).toEqual({ accountDid: did, connected: false });
  try { await cancelSkejSchedule(f.actor, item()); throw new Error("Expected rejection"); }
  catch (error) { expect(error).toBeInstanceOf(SkejSchedulingError); expect(error).toMatchObject({ code: "AccountNeedsReauth", status: 403 }); expect((error as Error).message).not.toContain("private provider detail"); }
  expect(f.mints.map(m => m.lxm)).toEqual(["at.skej.actor.getSession", "at.skej.schedule.cancel"]);
});

test("foreign and malformed calendar records fail closed", async () => {
  const f = fixture({ body: { records: [{ ...item(), did: "did:plc:someone-else" }] } });
  await expect(listSkejSchedules(f.actor)).rejects.toThrow("Invalid Scheduled Post");
});

test("a malformed schedule URI cannot escape the selected actor", async () => {
  const f = fixture({ body: { records: [{ ...item(), scheduleUri: "at://did:plc:someone-else/at.skej.schedule/schedule-one" }] } });
  await expect(listSkejSchedules(f.actor)).rejects.toThrow("Invalid Scheduled Post");
});

test("actor changes during token mint prevent an outbound scheduler request", async () => {
  let switched = false;
  const f = fixture({ afterMint: () => { switched = true; } });
  await expect(listSkejSchedules({ session, assertCurrentActor: () => { if (switched) throw new Error("Account Changed"); } })).rejects.toThrow("Account Changed");
  expect(f.mints).toHaveLength(1); expect(f.requests).toHaveLength(0);
});

test("create sends a canonical schedule with one stable publication key", async () => {
  const f = fixture(); await createSkejSchedule(f.actor, "A plain scheduled post", future);
  expect(f.mints[0].lxm).toBe("at.skej.schedule.create");
  const payload = f.requests[0].payload!, record = payload.record as SkejScheduleRecord;
  expect(payload.accountDid).toBe(did);
  expect(record).toMatchObject({ $type: "at.skej.schedule", scheduledAt: future, timezonePolicy: "absolute_utc", recordType: "app.bsky.feed.post", status: "scheduled", retry: { attemptCount: 0, maxAttempts: 8 }, posts: [{ text: "A plain scheduled post" }] });
  expect(record.posts[0].publishRkey).toBe(record.publishRkey); expect(record.publishRkey).toBeTruthy();
  expect(record.createdAt).toBe(record.updatedAt); expect(Number.isFinite(Date.parse(record.createdAt))).toBe(true);
  expect(f.requests[0].init.method).toBe("POST");
});

test("rescheduling preserves provider extensions, retry state, thread payload and publication keys", async () => {
  const f = fixture(), original = item();
  original.record.providerExtension = { keep: true }; original.record.posts[0].customEmbedding = { image: "original" };
  original.record.posts.push({ text: "Thread continuation", publishRkey: "second-post", facets: [{ custom: true }] });
  original.record.retry = { attemptCount: 2, maxAttempts: 9 };
  await rescheduleSkejPost(f.actor, original, "2099-02-01T12:00:00Z");
  expect(f.mints[0].lxm).toBe("at.skej.schedule.update");
  const payload = f.requests[0].payload!, record = payload.record as SkejScheduleRecord;
  expect(payload).toMatchObject({ accountDid: did, rkey: original.rkey });
  expect(record).toMatchObject({ providerExtension: { keep: true }, retry: original.record.retry, posts: original.record.posts, publishRkey: "stable-post", createdAt: original.record.createdAt, scheduledAt: "2099-02-01T12:00:00.000Z" });
  expect(original.record.scheduledAt).toBe(future);
});

test("published posts and invalid dates are rejected before minting or fetching", async () => {
  const f = fixture();
  await expect(rescheduleSkejPost(f.actor, { ...item(), status: "published" }, future)).rejects.toThrow("No Longer");
  await expect(createSkejSchedule(f.actor, "Post", "not a date")).rejects.toThrow("One Minute");
  expect(f.mints).toHaveLength(0); expect(f.requests).toHaveLength(0);
});

test("stores external previews in the scheduled publication payload", async () => {
  const f = fixture();
  const linkPreview = { uri: "https://example.com/story", title: "Scheduled Story", description: "Summary" };
  await createSkejSchedule(f.actor, linkPreview.uri, future, linkPreview);
  const record = f.requests[0].payload!.record as SkejScheduleRecord;
  expect(record.posts[0]).toMatchObject({ text: linkPreview.uri, embed: { $type: "app.bsky.embed.external", external: linkPreview } });
});

test("schedules native link-label text and retains its external card", async () => {
  const f = fixture();
  const linkPreview = { uri: "https://labs.xbox.com/", title: "XBOX Labs", description: "Explore" };
  await createSkejSchedule(f.actor, "[XBOX Labs](labs.xbox.com)", future, linkPreview);
  const record = f.requests[0].payload!.record as SkejScheduleRecord;
  expect(record.posts[0]).toMatchObject({ text: "XBOX Labs", facets: [{ index: { byteStart: 0, byteEnd: 9 }, features: [{ uri: linkPreview.uri }] }], embed: { external: linkPreview } });
});
