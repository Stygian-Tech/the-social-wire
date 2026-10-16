import { afterEach, expect, spyOn, test } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { IndexedDBReadStateOutbox, ReadStateProjection, type OutboxState, type ReadStateStatus } from "@thesocialwire/read-state";
import { pdsReadStateSync } from "@/lib/pdsReadStateSync";
import { markReadBefore } from "@/lib/feedReadAgeClient";
import { markAllReadOnGateway } from "@/lib/publicationProjectionClient";
import { writeThroughReadMark, writeThroughReadMarkDelete } from "@/lib/thinAppViewClient";
import * as Runtime from "@/lib/pdsReadStateRuntime";
import { queueReadStateMutation } from "@/lib/readStateMutationQueue";
import * as Gateway from "@/lib/socialWireGatewayClient";
import type { PreparedReadState } from "@/lib/pdsReadStateGateway";

const restores: (() => void)[] = [];
afterEach(() => { restores.splice(0).reverse().forEach(restore => restore()); });
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const status: ReadStateStatus = { authority: "pds", migrationState: "verified", legacyRevision: 1 };
const subject = { uri: "at://did:plc:author/site.standard.document/article", authorDid: "did:plc:author", publicationSite: "https://publication.test", createdAt: "2026-10-01T00:00:00Z" };
const prepared: PreparedReadState = { actedAt: "2026-10-16T01:00:00Z", legacyRevision: 1, selection: "boundaries", boundaries: [{ scope: { publicationId: "publication", authorDid: subject.authorDid, publicationSiteKeys: [subject.publicationSite] }, createdAt: "2026-10-16T00:00:00Z" }] };
function fixture(cached = true) {
  const locks = Object.getOwnPropertyDescriptor(navigator, "locks");
  Object.defineProperty(navigator, "locks", { configurable: true, value: { request: () => { throw new Error("Intent creation must not acquire the publishing lock"); } } });
  restores.push(() => { if (locks) Object.defineProperty(navigator, "locks", locks); else Reflect.deleteProperty(navigator, "locks"); });
  const enabled = process.env.NEXT_PUBLIC_PDS_READ_STATE_ENABLED;
  process.env.NEXT_PUBLIC_PDS_READ_STATE_ENABLED = "true";
  restores.push(() => { if (enabled === undefined) delete process.env.NEXT_PUBLIC_PDS_READ_STATE_ENABLED; else process.env.NEXT_PUBLIC_PDS_READ_STATE_ENABLED = enabled; });
  const customEvent = Object.getOwnPropertyDescriptor(globalThis, "CustomEvent");
  Object.defineProperty(globalThis, "CustomEvent", { configurable: true, value: window.CustomEvent });
  restores.push(() => { if (customEvent) Object.defineProperty(globalThis, "CustomEvent", customEvent); else Reflect.deleteProperty(globalThis, "CustomEvent"); });
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
  Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: {} });
  restores.push(() => { if (descriptor) Object.defineProperty(globalThis, "indexedDB", descriptor); else Reflect.deleteProperty(globalThis, "indexedDB"); });
  const viewer = "did:plc:runtime-order";
  let state: OutboxState = { viewerDid: viewer, entries: [], ...(cached ? { verifiedAuthority: status } : {}) };
  const read = spyOn(IndexedDBReadStateOutbox.prototype, "read").mockImplementation(async () => structuredClone(state));
  const update = spyOn(IndexedDBReadStateOutbox.prototype, "update").mockImplementation(async (_viewer, change) => { state = change(structuredClone(state)); return structuredClone(state); });
  restores.push(() => read.mockRestore(), () => update.mockRestore());
  const oauth = { did: viewer, fetchHandler: () => { throw new Error("unexpected repository request"); } } as unknown as OAuthSession;
  const runtime = pdsReadStateSync(oauth);
  restores.push(() => runtime.stop());
  const authority = spyOn(runtime.gateway, "status").mockResolvedValue(status);
  const prepare = spyOn(runtime.gateway, "prepare").mockResolvedValue(prepared);
  restores.push(() => authority.mockRestore(), () => prepare.mockRestore());
  return { oauth, runtime, authority, prepare, update, snapshot: () => structuredClone(state) };
}
function assertUnread(state: OutboxState, counter: number) {
  expect(state.entries.at(-1)?.intent.state).toBe("unread");
  expect(state.entries.at(-1)?.deviceCounter).toBe(counter);
  const operations = state.entries.map(entry => ({ ...entry.intent, sequence: entry.deviceCounter! }));
  expect(new ReadStateProjection(operations, counter).resolve(subject)).toMatchObject({ isRead: false, sequence: counter });
}

test("delayed bulk preparation cannot overtake newer exact unread in durable device order", async () => {
  const { runtime, prepare, snapshot } = fixture();
  const entered = deferred<void>(), response = deferred<PreparedReadState>();
  prepare.mockImplementation(() => { entered.resolve(); return response.promise; });
  const bulk = runtime.bulk({ kind: "subscribed" });
  await entered.promise;
  const unread = runtime.exact([subject.uri], "unread");
  expect(snapshot().entries).toHaveLength(0);
  response.resolve(prepared);
  await Promise.all([bulk, unread]);
  expect(snapshot().entries.map(entry => entry.intent.state)).toEqual(["read", "unread"]);
  assertUnread(snapshot(), 2);
});

test("delayed exact authority lookup reserves its invocation before bulk and newer unread", async () => {
  const { runtime, authority, prepare, snapshot } = fixture(false);
  const entered = deferred<void>(), response = deferred<ReadStateStatus>();
  authority.mockImplementationOnce(() => { entered.resolve(); return response.promise; });
  const first = runtime.exact([subject.uri], "read");
  await entered.promise;
  const bulk = runtime.bulk({ kind: "subscribed" });
  const unread = runtime.exact([subject.uri], "unread");
  expect(prepare).not.toHaveBeenCalled();
  response.resolve(status);
  await Promise.all([first, bulk, unread]);
  expect(snapshot().entries.map(entry => entry.intent.state)).toEqual(["read", "read", "unread"]);
  assertUnread(snapshot(), 3);
});

test("failed bulk preparation releases the queue for newer unread", async () => {
  const { runtime, prepare, snapshot } = fixture();
  const entered = deferred<void>(), response = deferred<PreparedReadState>();
  prepare.mockImplementationOnce(() => { entered.resolve(); return response.promise; });
  const bulk = runtime.bulk({ kind: "subscribed" });
  const failed = bulk.catch(error => error);
  await entered.promise;
  const unread = runtime.exact([subject.uri], "unread");
  response.reject(new Error("preparation failed"));
  expect(await failed).toMatchObject({ message: "preparation failed" });
  await unread;
  assertUnread(snapshot(), 1);
});

test("stop then retain cancels old preparation and queued intents without blocking new session", async () => {
  const { runtime, prepare, snapshot } = fixture();
  const entered = deferred<void>(), response = deferred<PreparedReadState>();
  prepare.mockImplementationOnce(() => { entered.resolve(); return response.promise; });
  const bulk = runtime.bulk({ kind: "subscribed" });
  const stoppedBulk = bulk.catch(error => error);
  await entered.promise;
  const oldExact = runtime.exact([subject.uri], "read");
  const stoppedExact = oldExact.catch(error => error);
  runtime.stop();
  const release = runtime.retain();
  await runtime.exact([subject.uri], "unread");
  response.resolve(prepared);
  for (const error of await Promise.all([stoppedBulk, stoppedExact])) expect(error).toMatchObject({ code: "reauthorize" });
  assertUnread(snapshot(), 1);
  expect(runtime.localError).toBeUndefined();
  release();
});

test("stop during delayed status cannot enqueue old exact after retain", async () => {
  const { runtime, authority, snapshot } = fixture(false);
  const entered = deferred<void>(), response = deferred<ReadStateStatus>();
  authority.mockImplementationOnce(() => { entered.resolve(); return response.promise; });
  const old = runtime.exact([subject.uri], "read");
  const stopped = old.catch(error => error);
  await entered.promise;
  runtime.stop();
  const release = runtime.retain();
  await runtime.exact([subject.uri], "unread");
  response.resolve(status);
  expect(await stopped).toMatchObject({ code: "reauthorize" });
  assertUnread(snapshot(), 1);
  release();
});

test("stop fences actual outbox update while previous enqueue awaits storage", async () => {
  const { runtime, update, snapshot } = fixture();
  const entered = deferred<void>(), resume = deferred<void>();
  const apply = update.getMockImplementation()!;
  let writes = 0;
  update.mockImplementation(async (viewer, change) => {
    if (++writes === 2) { entered.resolve(); await resume.promise; }
    return apply(viewer, change);
  });
  const old = runtime.exact([subject.uri], "read");
  const stopped = old.catch(error => error);
  await entered.promise;
  runtime.stop();
  const release = runtime.retain();
  await runtime.exact([subject.uri], "unread");
  resume.resolve();
  expect(await stopped).toMatchObject({ code: "reauthorize" });
  assertUnread(snapshot(), 1);
  release();
});

const publicWrites = [
  { name: "age", write: (oauth: OAuthSession) => markReadBefore(oauth, { kind: "subscribed" }, "2026-10-15T00:00:00Z", { timeZone: "UTC", referenceDate: "2026-10-16" }), counter: 2 },
  { name: "all", write: (oauth: OAuthSession) => markAllReadOnGateway(oauth, { kind: "subscribed" }), counter: 2 },
  { name: "exact", write: (oauth: OAuthSession) => writeThroughReadMark(oauth, subject.uri, "2026-10-16T01:00:00Z"), counter: 1 },
];
for (const action of publicWrites) {
  test(`public ${action.name} reserves ordering before cold authority and newer unread`, async () => {
    const { oauth, authority, snapshot } = fixture(false);
    const entered = deferred<void>(), response = deferred<ReadStateStatus>();
    authority.mockImplementationOnce(() => { entered.resolve(); return response.promise; });
    const first = action.write(oauth);
    await entered.promise;
    const newer = writeThroughReadMarkDelete(oauth, subject.uri);
    response.resolve(status);
    await Promise.all([first, newer]);
    expect(authority).toHaveBeenCalledTimes(1);
    assertUnread(snapshot(), action.counter);
  });
  test(`public ${action.name} retains ordering through delayed legacy409 transition`, async () => {
    const { oauth, authority, snapshot } = fixture(false);
    authority.mockResolvedValueOnce({ authority: "appview", migrationState: "notStarted", legacyRevision: 1 });
    const entered = deferred<void>(), response = deferred<Response>();
    const legacy = spyOn(Gateway, "gatewayFetch").mockImplementation(() => { entered.resolve(); return response.promise; });
    restores.push(() => legacy.mockRestore());
    const first = action.write(oauth);
    await entered.promise;
    const newer = writeThroughReadMarkDelete(oauth, subject.uri);
    response.resolve(Response.json({}, { status: 409 }));
    await Promise.all([first, newer]);
    expect(authority).toHaveBeenCalledTimes(2);
    expect(legacy).toHaveBeenCalledTimes(1);
    assertUnread(snapshot(), action.counter);
  });
}

test("public failed authority releases queue and stopped generation cannot issue legacy follow-up", async () => {
  const { oauth, runtime, authority, snapshot } = fixture(false);
  authority.mockRejectedValueOnce(new Error("authority unavailable"));
  const failed = markAllReadOnGateway(oauth, { kind: "subscribed" }).catch(error => error);
  const newer = writeThroughReadMarkDelete(oauth, subject.uri);
  expect(await failed).toMatchObject({ message: "authority unavailable" });
  await newer;
  assertUnread(snapshot(), 1);
  const entered = deferred<void>(), response = deferred<ReadStateStatus>();
  // Force a real delayed gate without changing the already-durable unread.
  const gate = spyOn(runtime, "status").mockImplementationOnce(() => { entered.resolve(); return response.promise; });
  restores.push(() => gate.mockRestore());
  const old = markAllReadOnGateway(oauth, { kind: "subscribed" }).catch(error => error);
  await entered.promise;
  runtime.stop();
  const release = runtime.retain();
  await writeThroughReadMarkDelete(oauth, subject.uri);
  response.resolve({ authority: "appview", migrationState: "notStarted", legacyRevision: 1 });
  expect(await old).toMatchObject({ name: "AbortError" });
  assertUnread(snapshot(), 1);
  release();
});

test("caller reservations remain isolated per captured OAuth account", async () => {
  const alice = { did: "did:plc:alice" } as unknown as OAuthSession;
  const bob = { did: "did:plc:bob" } as unknown as OAuthSession;
  const entered = deferred<void>(), response = deferred<void>();
  const writes: string[] = [];
  const first = queueReadStateMutation(alice, async assertCurrent => { entered.resolve(); await response.promise; assertCurrent(); writes.push(alice.did); });
  await entered.promise;
  await queueReadStateMutation(bob, async assertCurrent => { assertCurrent(); writes.push(bob.did); });
  expect(writes).toEqual([bob.did]);
  response.resolve();
  await first;
  expect(writes).toEqual([bob.did, alice.did]);
});

test("calls reserved while stopped cannot become valid when retain runs before the next microtask", async () => {
  const { oauth, runtime, snapshot } = fixture();
  runtime.stop();
  const caller = writeThroughReadMark(oauth, subject.uri, "2026-10-16T01:00:00Z").catch(error => error);
  const direct = runtime.exact([subject.uri], "read").catch(error => error);
  const release = runtime.retain();
  expect(await caller).toMatchObject({ name: "AbortError" });
  expect(await direct).toMatchObject({ code: "reauthorize" });
  expect(snapshot().entries).toHaveLength(0);
  await writeThroughReadMarkDelete(oauth, subject.uri);
  assertUnread(snapshot(), 1);
  release();
});

for (const action of [...publicWrites, { name: "unread", write: (oauth: OAuthSession) => writeThroughReadMarkDelete(oauth, subject.uri), counter: 1 }]) {
  test(`public ${action.name} makes one legacy attempt then uses verified canonical authority directly`, async () => {
    const { oauth, snapshot } = fixture();
    // A further nonforced probe would report legacy again. Once forced status
    // verified PDS authority, this action must never return to that path.
    const authority = spyOn(Runtime, "usesPDSReadState").mockResolvedValue(false)
      .mockResolvedValueOnce(false).mockResolvedValueOnce(true);
    const legacy = spyOn(Gateway, "gatewayFetch").mockResolvedValue(Response.json({}, { status: 409 }));
    restores.push(() => authority.mockRestore(), () => legacy.mockRestore());
    await action.write(oauth);
    expect(authority).toHaveBeenCalledTimes(2);
    expect(legacy).toHaveBeenCalledTimes(1);
    expect(snapshot().entries.at(-1)?.intent.state).toBe(action.name === "unread" ? "unread" : "read");
  });
}
