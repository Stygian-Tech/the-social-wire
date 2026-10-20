import { afterEach, beforeEach, expect, it } from "bun:test";
import { indexedDB as fakeIndexedDB } from "fake-indexeddb";
import { pendingDraftDeletions, saveDraftDeletion } from "@/lib/socialDraftDeletionStorage";

const previous = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
beforeEach(() => Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: fakeIndexedDB }));
afterEach(() => { if (previous) Object.defineProperty(globalThis, "indexedDB", previous); else Reflect.deleteProperty(globalThis, "indexedDB"); });

it("retains account-scoped deletion recovery until both private stores are cleaned", async () => {
  const draft = { id: "one", draft: { posts: [{ text: "Private" }] }, createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T00:00:00Z" };
  await saveDraftDeletion("did:plc:owner", draft);
  expect(await pendingDraftDeletions("did:plc:other")).toEqual([]);
  expect(await pendingDraftDeletions("did:plc:owner")).toEqual([{ ownerDid: "did:plc:owner", draft }]);
  await saveDraftDeletion("did:plc:owner", draft);
  expect(await pendingDraftDeletions("did:plc:owner")).toHaveLength(1);
  await saveDraftDeletion("did:plc:owner", draft, true);
  expect(await pendingDraftDeletions("did:plc:owner")).toEqual([]);
});

it("refuses deletion when durable recovery is unavailable", async () => {
  Reflect.deleteProperty(globalThis, "indexedDB");
  await expect(pendingDraftDeletions("did:plc:owner")).rejects.toThrow("Recovery Storage Is Unavailable");
});
