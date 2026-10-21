import { expect, it } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import { advanceFeedRefreshRevision, coalesceFeedFirstPage, getFeedRefreshRevision, invalidateReadFeedRefreshes } from "@/lib/feedRefreshCoordinator";

it("coalesces one feed scope while isolating OAuth reconnects and filters", async () => {
  const client = new QueryClient();
  const session = {};
  const reconnect = {};
  let release!: () => void;
  const barrier = new Promise<void>(resolve => { release = resolve; });
  let requests = 0;
  const fetchPage = async () => { requests++; await barrier; return "page"; };
  const first = coalesceFeedFirstPage(client, session, ["entries", "did:plc:alice", "pub", "all"], fetchPage);
  const same = coalesceFeedFirstPage(client, session, ["entries", "did:plc:alice", "pub", "all"], fetchPage);
  const unread = coalesceFeedFirstPage(client, session, ["entries", "did:plc:alice", "pub", "unread"], fetchPage);
  const reconnected = coalesceFeedFirstPage(client, reconnect, ["entries", "did:plc:alice", "pub", "all"], fetchPage);
  expect(same).toBe(first);
  expect(unread).not.toBe(first);
  expect(reconnected).not.toBe(first);
  expect(requests).toBe(3);
  release();
  await Promise.all([first, same, unread, reconnected]);
  await coalesceFeedFirstPage(client, session, ["entries", "did:plc:alice", "pub", "all"], fetchPage);
  expect(requests).toBe(4);
  client.clear();
});

it("releases a failed first-page attempt so retry can make progress", async () => {
  const client = new QueryClient();
  const session = {};
  await expect(coalesceFeedFirstPage(client, session, ["feed"], async () => { throw new Error("offline"); })).rejects.toThrow("offline");
  expect(await coalesceFeedFirstPage(client, session, ["feed"], async () => "recovered")).toBe("recovered");
  client.clear();
});

it("isolates revisions by client and complete query key with stable query hashing", () => {
  const client = new QueryClient();
  const otherClient = new QueryClient();
  const key = ["entries", "alice", "pub", "unread"];
  expect(getFeedRefreshRevision(client, key)).toBe(0);
  expect(advanceFeedRefreshRevision(client, key)).toBe(1);
  expect(advanceFeedRefreshRevision(client, [...key])).toBe(2);
  expect(getFeedRefreshRevision(otherClient, key)).toBe(0);
  for (const otherKey of [
    ["entries", "bob", "pub", "unread"],
    ["entries", "alice", "other", "unread"],
    ["entries", "alice", "pub", "all"],
    ["aggregateEntries", "alice", "pub", "unread"],
  ]) expect(getFeedRefreshRevision(client, otherKey)).toBe(0);
  advanceFeedRefreshRevision(client, ["feed", { id: "pub", kind: "list" }]);
  expect(getFeedRefreshRevision(client, ["feed", { kind: "list", id: "pub" }])).toBe(1);
});

it("allows a new revision to fetch while an older revision remains in flight", async () => {
  const client = new QueryClient();
  const session = {};
  const key = ["entries", "alice", "pub", "unread"];
  let release!: (value: string) => void;
  const old = coalesceFeedFirstPage(client, session, key, () => new Promise<string>(resolve => { release = resolve; }));
  advanceFeedRefreshRevision(client, key);
  let releaseNew!: (value: string) => void;
  const current = coalesceFeedFirstPage(client, session, key, () => new Promise<string>(resolve => { releaseNew = resolve; }));
  expect(current).not.toBe(old);
  release("old");
  expect(await old).toBe("old");
  expect(coalesceFeedFirstPage(client, session, key, async () => "unexpected")).toBe(current);
  releaseNew("new");
  expect(await current).toBe("new");
});

for (const domain of ["entries", "aggregateEntries"]) {
  it(`retires ${domain} work across query generations while preserving other domains and sessions`, async () => {
    const client = new QueryClient();
    const session = {}, otherSession = {};
    const key = [domain, "alice", "pub", "unread"];
    let finishOld!: (value: string) => void, finishNew!: (value: string) => void;
    const old = coalesceFeedFirstPage(client, session, key, () => new Promise<string>(resolve => { finishOld = resolve; }));
    advanceFeedRefreshRevision(client, key);
    const newer = coalesceFeedFirstPage(client, session, key, () => new Promise<string>(resolve => { finishNew = resolve; }));
    const other = coalesceFeedFirstPage(client, otherSession, key, async () => "other");
    const social = coalesceFeedFirstPage(client, session, ["social", "alice"], async () => "social");
    invalidateReadFeedRefreshes(client, session);
    let finishCurrent!: (value: string) => void;
    const current = coalesceFeedFirstPage(client, session, key, () => new Promise<string>(resolve => { finishCurrent = resolve; }));
    expect(current).not.toBe(newer);
    expect(coalesceFeedFirstPage(client, otherSession, key, async () => "unexpected")).toBe(other);
    expect(coalesceFeedFirstPage(client, session, ["social", "alice"], async () => "unexpected")).toBe(social);
    finishOld("old"); finishNew("newer");
    await Promise.all([old, newer]);
    expect(coalesceFeedFirstPage(client, session, key, async () => "unexpected")).toBe(current);
    finishCurrent("current");
    expect(await current).toBe("current");
    await Promise.all([other, social]);
    client.clear();
  });
}

for (const oldOutcome of ["reject", "resolve"] as const) {
  it(`retires aborted work before settlement and preserves its replacement after late ${oldOutcome}`, async () => {
    const client = new QueryClient();
    const session = {};
    const key = ["entries", "alice", "pub", "all"];
    const oldController = new AbortController();
    const currentController = new AbortController();
    let finishOld!: (value: string) => void, failOld!: (error: Error) => void;
    const old = coalesceFeedFirstPage(client, session, key, () => new Promise<string>((resolve, reject) => {
      finishOld = resolve;
      failOld = reject;
    }), oldController.signal);
    const oldResult = old.catch(error => error);
    oldController.abort();
    let finishCurrent!: (value: string) => void;
    const current = coalesceFeedFirstPage(client, session, key, () => new Promise<string>(resolve => {
      finishCurrent = resolve;
    }), currentController.signal);
    expect(current).not.toBe(old);
    expect(currentController.signal.aborted).toBe(false);
    if (oldOutcome === "reject") failOld(new DOMException("aborted", "AbortError"));
    else finishOld("retired");
    await oldResult;
    // Old finally cleanup cannot erase the still-active replacement.
    expect(coalesceFeedFirstPage(client, session, key, async () => "unexpected")).toBe(current);
    finishCurrent("fresh");
    expect(await current).toBe("fresh");
    expect(await coalesceFeedFirstPage(client, session, key, async () => "next")).toBe("next");
    client.clear();
  });
}

it("does not retain work whose owner signal was already aborted", async () => {
  const client = new QueryClient();
  const session = {};
  const controller = new AbortController();
  controller.abort();
  let finish!: (value: string) => void;
  const retired = coalesceFeedFirstPage(client, session, ["feed"], () => new Promise<string>(resolve => {
    finish = resolve;
  }), controller.signal);
  expect(await coalesceFeedFirstPage(client, session, ["feed"], async () => "fresh")).toBe("fresh");
  finish("retired");
  await retired;
  client.clear();
});
