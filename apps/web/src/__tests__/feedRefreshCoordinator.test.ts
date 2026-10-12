import { expect, it } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import { coalesceFeedFirstPage } from "@/lib/feedRefreshCoordinator";

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
