import { expect, test } from "bun:test";
import { dehydrate, hydrate, QueryClient, type Query } from "@tanstack/react-query";
import { prepareEntriesQueryPersistence, shouldPersistEntriesQuery } from "@/lib/entriesQueryPersist";
import { createIndexedDbQueryPersister } from "@/lib/indexedDbQueryPersister";
import { IDBFactory } from "fake-indexeddb";

function query(key: unknown[], counts = [1], status: Query["state"]["status"] = "success") {
  return {
    queryKey: key,
    state: { status, data: { pages: counts.map(count => ({ entries: Array(count).fill(null) })), pageParams: counts.map((_, i) => i ? `cursor-${i}` : undefined) } },
  };
}

test("persists private feeds only with a nonempty viewer key", () => {
  for (const kind of ["entries", "aggregateEntries"]) {
    expect(shouldPersistEntriesQuery(query([kind, "did:plc:viewer"]))).toBe(true);
    for (const viewer of [undefined, null, "", "signed-out", 42]) {
      expect(shouldPersistEntriesQuery(query([kind, viewer]))).toBe(false);
    }
  }
});

test("allows public Wire feeds without a viewer but rejects unknown query kinds", () => {
  for (const kind of ["wireEntries", "wireEditionMore"]) {
    expect(shouldPersistEntriesQuery(query([kind]))).toBe(true);
  }
  expect(shouldPersistEntriesQuery(query(["blueskySocial", "did:plc:viewer"]))).toBe(false);
});

test("selects successful feeds even after scrolling beyond the disk bounds", () => {
  expect(shouldPersistEntriesQuery(query(["wireEntries"], [50, 50, 50]))).toBe(true);
  expect(shouldPersistEntriesQuery(query(["wireEntries"], [51, 50, 50]))).toBe(true);
  expect(shouldPersistEntriesQuery(query(["wireEntries"], [1, 1, 1, 1]))).toBe(true);
  expect(shouldPersistEntriesQuery(query(["wireEntries"], []))).toBe(false);
  for (const status of ["pending", "error"] as const) {
    expect(shouldPersistEntriesQuery(query(["wireEntries"], [1], status))).toBe(false);
  }
});

test("restores a bounded complete prefix and its continuation after long reader/Circle sessions", () => {
  for (const namespace of ["entries", "aggregateEntries", "wireEntries", "wireEditionMore", "wireEdition", "circleEdition"]) {
    const source = new QueryClient();
    const key = [namespace, "did:plc:viewer", "test"];
    const rowsKey = namespace === "wireEdition" || namespace === "circleEdition" ? "stories" : "entries";
    const data = { pages: Array.from({ length: 8 }, (_, i) => ({ [rowsKey]: Array.from({ length: 50 }, (_, row) => ({ id: `${i}-${row}` })), cursor: `cursor-${i}`, moreCursor: `more-${i}` })), pageParams: [undefined, ...Array.from({ length: 7 }, (_, i) => `cursor-${i}`)] };
    source.setQueryData(key, data);
    const snapshot = prepareEntriesQueryPersistence({ timestamp: Date.now(), buster: "", clientState: dehydrate(source, { shouldDehydrateQuery: shouldPersistEntriesQuery }) });
    const restored = new QueryClient();
    hydrate(restored, structuredClone(snapshot.clientState));
    expect(restored.getQueryData<unknown>(key)).toEqual({ pages: data.pages.slice(0, 3), pageParams: data.pageParams.slice(0, 3) });
    expect(source.getQueryData<unknown>(key)).toBe(data);
    expect(restored.getQueryData([namespace, "did:plc:other", "test"])).toBeUndefined();
    source.clear(); restored.clear();
  }
});

test("retains complete page boundaries under the row cap", () => {
  const source = new QueryClient();
  const key = ["aggregateEntries", "did:plc:viewer", "subscribed"];
  const data = { pages: [80, 80, 20].map((n, i) => ({ entries: Array(n).fill(i), cursor: `cursor-${i}` })), pageParams: [undefined, "cursor-0", "cursor-1"] };
  source.setQueryData(key, data);
  const snapshot = prepareEntriesQueryPersistence({ timestamp: 1, buster: "", clientState: dehydrate(source) });
  expect(snapshot.clientState.queries[0].state.data).toEqual({ pages: data.pages.slice(0, 1), pageParams: [undefined] });
  source.clear();
});

test("oversized merged first pages restore bounded rows stale without a skipping cursor", () => {
  const source = new QueryClient();
  const key = ["entries", "did:plc:viewer", "publication", "all"];
  source.setQueryData(key, { pages: [{ entries: Array.from({ length: 180 }, (_, id) => ({ id })), cursor: "after-180" }], pageParams: [undefined] });
  const snapshot = prepareEntriesQueryPersistence({ timestamp: Date.now(), buster: "", clientState: dehydrate(source) });
  const restored = new QueryClient();
  hydrate(restored, snapshot.clientState);
  const data = restored.getQueryData<{ pages: { entries: unknown[]; cursor?: string }[] }>(key)!;
  expect(data.pages[0].entries).toHaveLength(150);
  expect(data.pages[0].cursor).toBeUndefined();
  expect(restored.getQueryState(key)?.dataUpdatedAt).toBe(1);
  expect(source.getQueryData<{ pages: { entries: unknown[] }[] }>(key)?.pages[0].entries).toHaveLength(180);
  source.clear(); restored.clear();
});

test("a failed background request preserves its last good reload snapshot", async () => {
  const source = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const key = ["aggregateEntries", "did:plc:viewer", "following", "", "all"];
  const data = { pages: [{ entries: [{ entryId: "received" }], cursor: "next" }], pageParams: [undefined] };
  source.setQueryData(key, data);
  await source.fetchQuery({ queryKey: key, queryFn: () => { throw new Error("Temporarily unavailable"); } }).catch(() => {});
  const snapshot = prepareEntriesQueryPersistence({ timestamp: Date.now(), buster: "", clientState: dehydrate(source, { shouldDehydrateQuery: shouldPersistEntriesQuery }) });
  const restored = new QueryClient();
  hydrate(restored, structuredClone(snapshot.clientState));
  expect(restored.getQueryData<unknown>(key)).toEqual(data);
  expect(restored.getQueryState(key)?.status).toBe("success");
  expect(source.getQueryState(key)?.status).toBe("error");
  source.clear(); restored.clear();
});

test("IndexedDB replaces a long-session snapshot with bounded content rather than an empty cache", async () => {
  const original = Object.getOwnPropertyDescriptor(window, "indexedDB");
  Object.defineProperty(window, "indexedDB", { configurable: true, value: new IDBFactory() });
  const source = new QueryClient();
  const restored = new QueryClient();
  const key = ["aggregateEntries", "did:plc:viewer", "subscribed", "", "all"];
  const persister = createIndexedDbQueryPersister({ dbName: "reader-persistence-regression", storeName: "queries", key: "snapshot", throttleTime: 0, prepareClient: prepareEntriesQueryPersistence });
  try {
    const pages = Array.from({ length: 5 }, (_, i) => ({ entries: [{ entryId: `page-${i}` }], cursor: `cursor-${i}` }));
    source.setQueryData(key, { pages, pageParams: [undefined, "cursor-0", "cursor-1", "cursor-2", "cursor-3"] });
    await persister.persistClient({ timestamp: Date.now(), buster: "", clientState: dehydrate(source, { shouldDehydrateQuery: shouldPersistEntriesQuery }) });
    let snapshot = await persister.restoreClient();
    for (let attempt = 0; !snapshot && attempt < 50; attempt++) {
      await new Promise(resolve => setTimeout(resolve, 5));
      snapshot = await persister.restoreClient();
    }
    expect(snapshot).toBeDefined();
    hydrate(restored, snapshot!.clientState);
    expect(restored.getQueryData<unknown>(key)).toEqual({ pages: pages.slice(0, 3), pageParams: [undefined, "cursor-0", "cursor-1"] });
    expect(source.getQueryData<{ pages: unknown[] }>(key)?.pages).toHaveLength(5);
  } finally {
    await persister.removeClient();
    source.clear(); restored.clear();
    if (original) Object.defineProperty(window, "indexedDB", original);
    else Reflect.deleteProperty(window, "indexedDB");
  }
});
