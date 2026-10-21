import { expect, it } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import { advanceFeedRefreshRevision, coalesceFeedFirstPage, getFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";

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

it("retires only viewer reader work synchronously without reverting optimism or freshness", async () => {
  const { cancelViewerFeedRefreshes } = await import("@/lib/feedRefreshCoordinator");
  const client = new QueryClient();
  const key = ["entries", "did:plc:viewer", "pub", "all"];
  const aggregate = ["aggregateEntries", "did:plc:viewer", "folder", "folder", "unread"];
  const other = ["entries", "did:plc:other", "pub", "all"];
  const social = ["blueskySocial", "did:plc:viewer", "feed"];
  for (const scope of [key, aggregate, other, social]) client.setQueryData(scope, "baseline", { updatedAt: 1 });
  let finish!: (value: string) => void;
  const stale = client.fetchQuery({ queryKey: key, queryFn: () => new Promise<string>(resolve => { finish = resolve; }) }).catch(() => undefined);
  const retired = cancelViewerFeedRefreshes(client, "did:plc:viewer");
  expect(getFeedRefreshRevision(client, key)).toBe(1);
  expect(getFeedRefreshRevision(client, aggregate)).toBe(1);
  expect(getFeedRefreshRevision(client, other)).toBe(0);
  expect(getFeedRefreshRevision(client, social)).toBe(0);
  client.setQueryData(key, "optimistic", { updatedAt: 2 });
  await client.invalidateQueries({ queryKey: key, exact: true, refetchType: "none" });
  finish("stale");
  await Promise.all([retired, stale]);
  expect(client.getQueryState(key)).toMatchObject({ data: "optimistic", dataUpdatedAt: 2, isInvalidated: true, status: "success", fetchStatus: "idle" });
  client.clear();
});
