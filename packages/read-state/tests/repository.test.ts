import { describe, expect, test } from "bun:test";
import { CHUNK_COLLECTION, MANIFEST_COLLECTION, ReadStateError, commitIntent, commitIntents,
  loadGeneration, recordCID, type Chunk } from "../src";
import { Repository, at, intent } from "./fixture";

describe("PDS read-state generations", () => {
  test("immutable chunks precede manifest and retries after unknown success do not repeat intent", async () => {
    const repo = new Repository(); repo.failAfterManifest = true;
    await expect(commitIntent(repo, intent("a"))).rejects.toThrow("Lost response");
    const ref = await commitIntent(repo, intent("a"));
    expect(ref.cid).toBe(repo.manifest().cid);
    expect(repo.writes).toEqual([CHUNK_COLLECTION, MANIFEST_COLLECTION]);
    expect((await loadGeneration(repo)).projection.lastSequence).toBe(1);
  });
  test("large exact sets split by actual byte size without partial publication", async () => {
    const repo = new Repository();
    const uris = Array.from({ length: 2000 }, (_, i) => `https://example.test/${i}/${"x".repeat(1000)}`);
    await commitIntent(repo, intent("large", "read", uris));
    const loaded = await loadGeneration(repo);
    expect(loaded.projection.operations.flatMap(operation => operation.subjectUris ?? []).sort()).toEqual(uris.sort());
    expect(repo.chunks().length).toBeGreaterThan(30);
    expect(repo.writes.at(-1)).toBe(MANIFEST_COLLECTION);
    for (const chunk of repo.chunks()) expect(new TextEncoder().encode(JSON.stringify(chunk.value)).length).toBeLessThanOrEqual(65536);
  });
  test("CAS conflict merges remote action and assigns order from manifest rather than device clock", async () => {
    const repo = new Repository(); let injected = false;
    repo.beforePut = async collection => {
      if (collection === MANIFEST_COLLECTION && !injected) {
        injected = true; repo.beforePut = undefined;
        await commitIntent(repo, intent("other-device", "read"));
      }
    };
    await commitIntent(repo, { ...intent("offline-device", "unread"), actedAt: "2020-01-01T00:00:00Z" });
    const loaded = await loadGeneration(repo);
    expect(loaded.projection.actionIds).toEqual(new Set(["other-device", "offline-device"]));
    expect(loaded.projection.resolve({ uri: "at://article/a", authorDid: "did:plc:author", createdAt: at }).isRead).toBe(false);
    expect(loaded.manifest.lastSequence).toBe(2);
  });
  test("missing or altered referenced chunks reject the entire state", async () => {
    const repo = new Repository(); await commitIntent(repo, intent("a"));
    const chunk = repo.chunks()[0];
    const key = chunk.uri.split("/").slice(-2).join("/");
    repo.records.delete(key);
    await expect(loadGeneration(repo)).rejects.toThrow("incomplete_generation");
    repo.records.set(key, { ...chunk, value: { ...(chunk.value as Chunk), operations: [] } });
    await expect(loadGeneration(repo)).rejects.toThrow("invalid_cid");
  });
  test("CID-verified foreign viewer references and conflicting action reuse fail closed", async () => {
    const repo = new Repository(); await commitIntent(repo, intent("a"));
    await expect(commitIntent(repo, intent("a", "unread"))).rejects.toThrow("conflicting_sequence");
    const manifest = structuredClone(repo.manifest());
    (manifest.value as { head: { uri: string } }).head.uri = "at://did:plc:bob/app.thesocialwire.readStateChunk/key";
    manifest.cid = await recordCID(manifest.value);
    repo.records.set(`${MANIFEST_COLLECTION}/self`, manifest);
    await expect(loadGeneration(repo)).rejects.toThrow("invalid_reference");
  });
  test("many distinct pending actions share a chunk and single CAS without dropping ordering", async () => {
    const repo = new Repository();
    await commitIntents(repo, Array.from({ length: 32 }, (_, i) => intent(`${i}`, i % 2 ? "unread" : "read")));
    expect(repo.writes).toEqual([CHUNK_COLLECTION, MANIFEST_COLLECTION]);
    expect((await loadGeneration(repo)).manifest.lastSequence).toBe(32);
  });
});

test("fragmented histories repack without pruning committed retry identities or sequence order", async () => {
  const repo = new Repository();
  for (let i = 0; i < 70; i++) await commitIntent(repo, intent(`action-${i}`, i % 2 ? "unread" : "read"));
  const loaded = await loadGeneration(repo);
  expect(loaded.chunkCount).toBeLessThan(10);
  expect(loaded.projection.operations).toHaveLength(70);
  expect(loaded.manifest.lastSequence).toBe(70);
  const cid = loaded.record!.cid;
  expect((await commitIntent(repo, intent("action-0"))).cid).toBe(cid);
  expect((await loadGeneration(repo)).manifest.lastSequence).toBe(70);
});

test("an oversized complete candidate fails before any public upload", async () => {
  const repo = new Repository();
  const uris = Array.from({ length: 9000 }, (_, i) => `at://entry/${i}/${"a".repeat(1980)}`);
  await expect(commitIntent(repo, intent("too-large", "read", uris))).rejects.toThrow("size_limit");
  expect(repo.writes).toHaveLength(0);
});

test("unknown chunk metadata disables repacking while operation extensions are retained", async () => {
  const repo = new Repository();
  const chunk = { $type: CHUNK_COLLECTION, version: 1, operations: [{ ...intent("future"), sequence: 1, futureOperation: "keep" }], futureChunk: "keep" } as unknown as Chunk;
  const cid = await recordCID(chunk);
  const head = await repo.putRecord(CHUNK_COLLECTION, cid, chunk, null);
  await repo.putRecord(MANIFEST_COLLECTION, "self", { $type: MANIFEST_COLLECTION, version: 1, generation: "future", lastSequence: 1, head }, null);
  const generation = await loadGeneration(repo);
  expect(generation.repackAllowed).toBe(false);
  expect(generation.projection.operations[0]).toHaveProperty("futureOperation", "keep");
  await commitIntent(repo, intent("new"));
  expect((await loadGeneration(repo)).projection.operations.find(operation => operation.actionId === "future")).toHaveProperty("futureOperation", "keep");
});
