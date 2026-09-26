import { expect, test } from "bun:test";
import { migrateReadState, loadGeneration, type MigrationCheckpoint, type ReadStateMigrationGateway } from "../src";
import { Repository, at } from "./fixture";

test("migration resumes export and confirms only a complete public generation at the fenced revision", async () => {
  const repo = new Repository(); let checkpoint: MigrationCheckpoint | null = null; let unavailable = true; let confirmed = 0;
  const store = { read: async () => structuredClone(checkpoint), write: async (_viewer: string, value: MigrationCheckpoint | null) => { checkpoint = structuredClone(value); } };
  const cursors: (string | undefined)[] = [];
  const gateway: ReadStateMigrationGateway = {
    status: async () => ({ authority: "appview", migrationState: "notStarted", legacyRevision: 3 }),
    exportPage: async (cursor, expected) => {
      cursors.push(cursor);
      if (!cursor) return { legacyRevision: 3, rows: [{ kind: "unread", subjectUri: "a", actedAt: at }], cursor: "next" };
      expect(expected).toBe(3); if (unavailable) throw new Error("Offline");
      return { legacyRevision: 3, rows: [{ kind: "read", subjectUri: "b", actedAt: at }] };
    },
    confirm: async (reference, revision) => {
      confirmed++; expect(revision).toBe(3); expect(reference.cid).toBe(repo.manifest().cid);
      const loaded = await loadGeneration(repo); expect(loaded.projection.operations).toHaveLength(2);
      return { authority: "pds", migrationState: "verified", legacyRevision: 3, manifestCid: reference.cid };
    },
  };
  await expect(migrateReadState(repo, gateway, store)).rejects.toThrow("Offline");
  expect(repo.writes).toHaveLength(0); expect(confirmed).toBe(0);
  unavailable = false;
  expect((await migrateReadState(repo, gateway, store)).authority).toBe("pds");
  expect(cursors).toEqual([undefined, "next", "next"]); expect(checkpoint).toBeNull();
});
test("mutations during migration cause revision conflict without granting authority or losing existing projection", async () => {
  const repo = new Repository(); let checkpoint: MigrationCheckpoint | null = null;
  const store = { read: async () => checkpoint, write: async (_viewer: string, value: MigrationCheckpoint | null) => { checkpoint = value; } };
  let confirmCalls = 0;
  const gateway: ReadStateMigrationGateway = {
    status: async () => ({ authority: "appview", migrationState: "notStarted", legacyRevision: 1 }),
    exportPage: async (cursor) => cursor ? { legacyRevision: 2, rows: [] }
      : { legacyRevision: 1, rows: [{ kind: "read", subjectUri: "a", actedAt: at }], cursor: "next" },
    confirm: async () => { confirmCalls++; throw new Error("must not confirm"); },
  };
  await expect(migrateReadState(repo, gateway, store)).rejects.toThrow("conflict");
  expect(confirmCalls).toBe(0); expect(repo.writes).toHaveLength(0);
});

test("a legacy mutation after publication re-exports and replaces only the unactivated baseline", async () => {
  const repo = new Repository(); let checkpoint: MigrationCheckpoint | null = null; let revision = 1;
  const store = { read: async () => checkpoint, write: async (_viewer: string, value: MigrationCheckpoint | null) => { checkpoint = value; } };
  let firstCandidate: string | undefined;
  const gateway: ReadStateMigrationGateway = {
    status: async () => ({ authority: "appview", migrationState: "notStarted", legacyRevision: revision }),
    exportPage: async () => ({ legacyRevision: revision, rows: [{ kind: "read", subjectUri: `article-${revision}`, actedAt: at }] }),
    confirm: async (reference, expected) => {
      if (revision === 1) { firstCandidate = reference.cid; revision = 2; throw new Error("Revision changed"); }
      expect(expected).toBe(2); expect(reference.cid).not.toBe(firstCandidate);
      const generation = await loadGeneration(repo);
      expect(generation.projection.operations).toHaveLength(1);
      expect(generation.projection.operations[0].subjectUris).toEqual(["article-2"]);
      return { authority: "pds", migrationState: "verified", legacyRevision: revision, manifestCid: reference.cid };
    },
  };
  await expect(migrateReadState(repo, gateway, store)).rejects.toThrow("Revision changed");
  expect((checkpoint as MigrationCheckpoint | null)?.committed?.cid).toBe(firstCandidate);
  expect((await migrateReadState(repo, gateway, store)).authority).toBe("pds");
  expect(checkpoint).toBeNull();
});

test("a second device activating during upload wins without replacement or another confirmation", async () => {
  const repo = new Repository(); let checkpoint: MigrationCheckpoint | null = null; let canonical = false; let confirmations = 0;
  const store = { read: async () => checkpoint, write: async (_viewer: string, value: MigrationCheckpoint | null) => { checkpoint = value; } };
  const { MANIFEST_COLLECTION, publishMigration } = await import("../src");
  repo.beforePut = async collection => {
    if (collection !== MANIFEST_COLLECTION) return;
    repo.beforePut = undefined;
    await publishMigration(repo, "other-device", [{ actionId: "other-action", state: "read", actedAt: at, selection: "exact", subjectUris: ["other"] }], null);
    canonical = true;
  };
  const gateway: ReadStateMigrationGateway = {
    status: async () => ({ authority: canonical ? "pds" : "appview", migrationState: canonical ? "verified" : "notStarted", legacyRevision: 1 }),
    exportPage: async () => ({ legacyRevision: 1, rows: [{ kind: "read", subjectUri: "legacy", actedAt: at }] }),
    confirm: async () => { confirmations++; throw new Error("must not confirm stale candidate"); },
  };
  expect((await migrateReadState(repo, gateway, store)).authority).toBe("pds");
  expect((await loadGeneration(repo)).manifest.generation).toBe("other-device");
  expect(confirmations).toBe(0); expect(checkpoint).toBeNull();
});
