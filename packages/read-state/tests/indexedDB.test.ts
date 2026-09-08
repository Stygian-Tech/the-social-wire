import { expect, test } from "bun:test";
import { IDBFactory } from "fake-indexeddb";
import { IndexedDBReadStateOutbox, ReadStateOutbox } from "../src";
import { Repository, intent, lock, viewer, at } from "./fixture";

test("IndexedDB queue survives store recreation, isolates viewers, and atomically retains concurrent enqueues", async () => {
  const factory = new IDBFactory(); const store = new IndexedDBReadStateOutbox(factory);
  await Promise.all(Array.from({ length: 10 }, (_, i) => store.update(viewer, state => ({ ...state,
    entries: [...state.entries, { intent: intent(`a${i}`), attempts: 0, retryAt: 0 }] }))));
  const reopened = new IndexedDBReadStateOutbox(factory);
  expect((await reopened.read(viewer)).entries).toHaveLength(10);
  expect((await reopened.read("did:plc:bob")).entries).toHaveLength(0);
  await expect(reopened.update(viewer, state => ({ ...state, viewerDid: "did:plc:bob" }))).rejects.toThrow();
  expect((await reopened.read(viewer)).entries).toHaveLength(10);
});
test("slow PDS export does not block durably accepting a newer offline intent", async () => {
  const factory = new IDBFactory(); const store = new IndexedDBReadStateOutbox(factory); const repo = new Repository();
  let release!: () => void; let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const pending = new Promise<void>(resolve => { release = resolve; });
  repo.beforePut = async () => { entered(); await pending; };
  const outbox = new ReadStateOutbox(store, repo, async () => {}, lock());
  await outbox.enqueue(intent("first"));
  const flush = outbox.flushOnce(); await started;
  await outbox.enqueue(intent("newer", "unread"));
  expect((await new IndexedDBReadStateOutbox(factory).read(viewer)).entries.map(entry => entry.intent.actionId)).toEqual(["first", "newer"]);
  release(); expect(await flush).toBe(true);
  expect((await outbox.snapshot()).entries.map(entry => entry.intent.actionId)).toEqual(["newer"]);
});

test("server-validated boundary previews survive storage restart and never enter public operations", async () => {
  const repository = new Repository();
  const factory = new IDBFactory();
  const store = new IndexedDBReadStateOutbox(factory);
  const outbox = new ReadStateOutbox(store, repository, async () => {}, lock());
  const action = { actionId: "boundary", state: "read" as const, actedAt: at, selection: "boundaries" as const,
    boundaries: [{ scope: { publicationId: "publication", authorDid: "did:plc:author", publicationSiteKeys: [] }, createdAt: at }] };
  await outbox.enqueue(action, ["validated-article"]);
  expect((await new IndexedDBReadStateOutbox(factory).read(repository.viewerDid)).entries[0].previewSubjectUris).toEqual(["validated-article"]);
  await outbox.flushOnce();
  expect(JSON.stringify(repository.chunks())).not.toContain("previewSubjectUris");
  expect(JSON.stringify(repository.chunks())).not.toContain("validated-article");
});
