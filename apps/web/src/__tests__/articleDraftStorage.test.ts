import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { IDBFactory, IDBObjectStore, IDBCursor } from "fake-indexeddb";
import type { ArticleDraft } from "@/lib/articles/articleDraftTypes";
import { deleteArticleDraft, getArticleDraft, getArticleDraftAsset, listArticleDrafts, saveArticleDraft, saveArticleDraftAsset } from "@/lib/articles/articleDraftStorage";
const alice = "did:plc:alice";
const bob = "did:plc:bob";
const originalIDB = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
const restores: (() => void)[] = [];
function draft(id = "one"): ArticleDraft { return { id, title: "Private Draft", markdown: "# Untitled", excerpt: "", path: "untitled", tags: [], publicationUri: "", createdAt: "2026-10-10T00:00:00Z", updatedAt: "2026-10-10T00:00:00Z" }; }
beforeEach(() => Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: new IDBFactory() }));
afterEach(() => { restores.splice(0).forEach(restore => restore()); if (originalIDB) Object.defineProperty(globalThis, "indexedDB", originalIDB); else Reflect.deleteProperty(globalThis, "indexedDB"); });
describe("private article draft repository", () => {
  it("isolates drafts and private blobs by account and draft even with identical IDs", async () => {
    await saveArticleDraft(alice, draft()); await saveArticleDraft(bob, { ...draft(), title: "Bob's Draft" });
    await saveArticleDraft(alice, draft("two"));
    await saveArticleDraftAsset(alice, "one", "cover", new Blob(["alice"], { type: "image/png" }));
    await saveArticleDraftAsset(bob, "one", "cover", new Blob(["bob"], { type: "image/png" }));
    expect((await listArticleDrafts(alice)).map(value => value.title)).toEqual(["Private Draft", "Private Draft"]);
    expect((await listArticleDrafts(bob)).map(value => value.title)).toEqual(["Bob's Draft"]);
    expect(await (await getArticleDraftAsset(alice, "one", "cover"))!.text()).toBe("alice");
    expect(await (await getArticleDraftAsset(bob, "one", "cover"))!.text()).toBe("bob");
    expect(await getArticleDraftAsset(alice, "two", "cover")).toBeUndefined();
    await deleteArticleDraft(alice, "one");
    expect(await getArticleDraft(alice, "one")).toBeUndefined();
    expect(await getArticleDraftAsset(alice, "one", "cover")).toBeUndefined();
    expect(await getArticleDraft(bob, "one")).toBeDefined();
    expect(await getArticleDraftAsset(bob, "one", "cover")).toBeDefined();
    expect(await getArticleDraft(alice, "two")).toBeDefined();
  });
  it("prevents stale cross-tab saves and preserves createdAt while normalizing optional assets", async () => {
    const first = await saveArticleDraft(alice, draft());
    expect(first).toMatchObject({ revision: 1, assets: [] });
    const next = await saveArticleDraft(alice, { ...first, title: "Newest", createdAt: "2026-10-11T00:00:00Z", updatedAt: "2026-10-12T00:00:00Z" });
    expect(next).toMatchObject({ revision: 2, createdAt: first.createdAt });
    await expect(saveArticleDraft(alice, { ...first, title: "Stale" })).rejects.toThrow("changed in another tab");
    expect((await getArticleDraft(alice, first.id))!.title).toBe("Newest");
    await saveArticleDraft(alice, draft("older"));
    expect((await listArticleDrafts(alice)).map(value => value.id)).toEqual(["one", "older"]);
  });
  it("reads legacy drafts without asset descriptors and preserves image metadata on save", async () => {
    await saveArticleDraft(alice, draft());
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("the-social-wire.article-drafts.v1", 1);
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction("drafts", "readwrite");
      tx.objectStore("drafts").put({ viewerDid: alice, draftId: "legacy", draft: draft("legacy") });
      tx.oncomplete = () => resolve(); tx.onabort = () => reject(tx.error);
    });
    db.close();
    expect((await getArticleDraft(alice, "legacy"))!.assets).toEqual([]);
    expect((await listArticleDrafts(alice)).every(value => Array.isArray(value.assets))).toBe(true);
    const asset = { id: "cover", alt: "A Forest", width: 1280, height: 720, mimeType: "image/png", name: "forest.png" };
    const legacy = (await getArticleDraft(alice, "legacy"))!;
    await saveArticleDraft(alice, { ...legacy, assets: [asset], coverAssetId: "cover" });
    expect((await getArticleDraft(alice, "legacy"))!.assets).toEqual([asset]);
  });
  it("preserves existing drafts and asset blobs when a replacement exceeds quota", async () => {
    const saved = await saveArticleDraft(alice, draft());
    await saveArticleDraftAsset(alice, "one", "cover", new Blob(["original"]));
    const put = spyOn(IDBObjectStore.prototype, "put").mockImplementation(() => { throw new DOMException("Quota exceeded", "QuotaExceededError"); }); restores.push(() => put.mockRestore());
    await expect(saveArticleDraft(alice, { ...saved, markdown: "replacement" })).rejects.toThrow("Quota exceeded");
    await expect(saveArticleDraftAsset(alice, "one", "cover", new Blob(["replacement"]))).rejects.toThrow("Quota exceeded");
    put.mockRestore();
    expect((await getArticleDraft(alice, "one"))!.markdown).toBe("# Untitled");
    expect(await (await getArticleDraftAsset(alice, "one", "cover"))!.text()).toBe("original");
  });
  it("rolls back draft deletion when asset cleanup fails in its shared transaction", async () => {
    await saveArticleDraft(alice, draft());
    await saveArticleDraftAsset(alice, "one", "cover", new Blob(["original"]));
    const remove = spyOn(IDBCursor.prototype, "delete").mockImplementation(() => { throw new Error("Asset cleanup failed"); }); restores.push(() => remove.mockRestore());
    await expect(deleteArticleDraft(alice, "one")).rejects.toThrow("Asset cleanup failed");
    remove.mockRestore();
    expect(await getArticleDraft(alice, "one")).toBeDefined();
    expect(await getArticleDraftAsset(alice, "one", "cover")).toBeDefined();
  });
  it("rejects unavailable storage and orphan assets without a lossy fallback", async () => {
    await expect(saveArticleDraftAsset(alice, "absent", "cover", new Blob(["no"]))).rejects.toThrow("Save the draft");
    Reflect.deleteProperty(globalThis, "indexedDB");
    await expect(saveArticleDraft(alice, draft())).rejects.toThrow("require IndexedDB");
    await expect(listArticleDrafts("")).rejects.toThrow("viewer DID");
  });
});
