import { describe, expect, test } from "bun:test";
import { PDSRequestError, ReadStateOutbox, loadGeneration } from "../src";
import { Repository, Store, intent, lock, viewer } from "./fixture";

describe("durable read-state outbox", () => {
  test("restart after unknown PDS success retries confirmation without duplicate public action", async () => {
    const repo = new Repository(); const store = new Store(); const locked = lock(); let now = 1000;
    const create = () => new ReadStateOutbox(store, repo, async () => {}, locked, () => now, () => 0);
    const first = create(); await first.enqueue(intent("a")); repo.failAfterManifest = true;
    expect(await first.flushOnce()).toBe(false);
    expect((await first.snapshot()).entries).toHaveLength(1);
    now += 2000;
    const restarted = create(); expect(await restarted.flushOnce()).toBe(true);
    expect((await restarted.snapshot()).entries).toHaveLength(0);
    expect((await loadGeneration(repo)).manifest.lastSequence).toBe(1);
    expect(repo.writes).toHaveLength(2);
  });
  test("Retry-After is persisted and later intents cannot bypass a throttled account", async () => {
    const repo = new Repository(); const store = new Store(); let now = 1000;
    const outbox = new ReadStateOutbox(store, repo, async () => {}, lock(), () => now, () => 0);
    await outbox.enqueue(intent("a")); repo.beforePut = async () => { throw new PDSRequestError(429, "120"); };
    expect(await outbox.flushOnce()).toBe(false);
    await outbox.enqueue(intent("b", "unread"));
    now += 119_000; expect(await outbox.flushOnce()).toBe(false);
    expect((await outbox.snapshot()).entries).toHaveLength(2);
    now += 1000; repo.beforePut = undefined;
    expect(await outbox.flushOnce()).toBe(true);
    expect((await loadGeneration(repo)).manifest.lastSequence).toBe(2);
  });
  test("unattempted adjacent duplicate selections coalesce while unrelated and attempted intents survive", async () => {
    const repo = new Repository(); const store = new Store();
    const outbox = new ReadStateOutbox(store, repo, async () => {}, lock());
    await outbox.enqueue(intent("a")); await outbox.enqueue(intent("b", "unread"));
    await outbox.enqueue(intent("other", "read", ["another"])); await outbox.enqueue(intent("c"));
    expect((await outbox.snapshot()).entries.map(entry => entry.intent.actionId)).toEqual(["b", "other", "c"]);
    await store.update("did:plc:bob", state => ({ ...state, entries: [{ intent: intent("bob"), attempts: 0, retryAt: 0 }] }));
    expect(await outbox.flushOnce()).toBe(true);
    expect((await store.read("did:plc:bob")).entries).toHaveLength(1);
    expect((await store.read(viewer)).entries).toHaveLength(0);
  });
  test("server projection failure preserves committed intent until parity confirmation succeeds", async () => {
    const repo = new Repository(); const store = new Store(); let now = 0; let available = false;
    const outbox = new ReadStateOutbox(store, repo, async () => { if (!available) throw new Error("Offline"); }, lock(), () => now, () => 0);
    await outbox.enqueue(intent("a")); expect(await outbox.flushOnce()).toBe(false);
    expect((await outbox.snapshot()).entries[0].committed).toBeDefined();
    available = true; now = 1000; expect(await outbox.flushOnce()).toBe(true);
    expect(repo.writes).toHaveLength(2);
  });
  test("concurrent flushes serialize per viewer and never publish duplicate sequences", async () => {
    const repo = new Repository(); const store = new Store(); const sharedLock = lock();
    const first = new ReadStateOutbox(store, repo, async () => {}, sharedLock);
    const second = new ReadStateOutbox(store, repo, async () => {}, sharedLock);
    await first.enqueue(intent("a"));
    expect(await Promise.all([first.flushOnce(), second.flushOnce()])).toEqual([true, false]);
    expect((await loadGeneration(repo)).manifest.lastSequence).toBe(1);
  });
});
