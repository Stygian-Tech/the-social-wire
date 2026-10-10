import type { ArticleDraft } from "./articleDraftTypes";

const DB_NAME = "the-social-wire.article-drafts.v1";
const DRAFTS = "drafts";
const ASSETS = "assets";
const connections = new WeakMap<IDBFactory, Promise<IDBDatabase>>();
type DraftRow = { viewerDid: string; draftId: string; draft: ArticleDraft };
type AssetRow = { viewerDid: string; draftId: string; assetId: string; blob: Blob };

function normalizeDraft(draft: ArticleDraft): ArticleDraft {
  return { ...draft, assets: draft.assets ?? [] };
}

function requireKey(viewerDid: string, ...ids: string[]) {
  if (!/^did:[a-z]+:[^\s/?#]+$/.test(viewerDid) || ids.some(id => !id || id.length > 512)) throw new Error("A viewer DID and valid draft identifiers are required.");
}

async function openDatabase(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") throw new Error("Private article drafts require IndexedDB. Browser storage is unavailable.");
  const factory = indexedDB;
  let connection = connections.get(factory);
  if (!connection) {
    connection = new Promise((resolve, reject) => {
      const request = factory.open(DB_NAME, 1);
      let failed = false;
      const fail = (error: Error) => { failed = true; connections.delete(factory); reject(error); };
      request.onupgradeneeded = () => {
        const drafts = request.result.createObjectStore(DRAFTS, { keyPath: ["viewerDid", "draftId"] });
        drafts.createIndex("viewer", "viewerDid");
        const assets = request.result.createObjectStore(ASSETS, { keyPath: ["viewerDid", "draftId", "assetId"] });
        assets.createIndex("draft", ["viewerDid", "draftId"]);
      };
      request.onerror = () => fail(request.error ?? new Error("Private draft storage could not be opened."));
      request.onblocked = () => fail(new Error("Private draft storage is blocked by another browser tab. Close that tab and retry."));
      request.onsuccess = () => {
        const db = request.result;
        if (failed) { db.close(); return; }
        db.onversionchange = () => { db.close(); connections.delete(factory); };
        resolve(db);
      };
    });
    connections.set(factory, connection);
  }
  return connection;
}

function transaction<T>(db: IDBDatabase, stores: string[], mode: IDBTransactionMode, work: (tx: IDBTransaction, result: (value: T) => void, fail: (error: Error) => void) => void): Promise<T> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(stores, mode);
    let value: T;
    const fail = (error: Error) => { reject(error); try { tx.abort(); } catch { /* Already aborted or completed. */ } };
    tx.oncomplete = () => resolve(value);
    tx.onabort = () => reject(tx.error ?? new Error("Private draft storage transaction was aborted. Your previous draft is preserved."));
    tx.onerror = () => reject(tx.error ?? new Error("Private draft storage transaction failed. Your previous draft is preserved."));
    try { work(tx, result => { value = result; }, fail); } catch (error) { fail(error instanceof Error ? error : new Error(String(error))); }
  });
}

export async function listArticleDrafts(viewerDid: string): Promise<ArticleDraft[]> {
  requireKey(viewerDid);
  return transaction(await openDatabase(), [DRAFTS], "readonly", (tx, result) => {
    const request = tx.objectStore(DRAFTS).index("viewer").getAll(viewerDid);
    request.onsuccess = () => result((request.result as DraftRow[]).map(row => normalizeDraft(row.draft)).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)));
  });
}

export async function getArticleDraft(viewerDid: string, draftId: string): Promise<ArticleDraft | undefined> {
  requireKey(viewerDid, draftId);
  return transaction(await openDatabase(), [DRAFTS], "readonly", (tx, result) => {
    const request = tx.objectStore(DRAFTS).get([viewerDid, draftId]);
    request.onsuccess = () => { const draft = (request.result as DraftRow | undefined)?.draft; result(draft ? normalizeDraft(draft) : undefined); };
  });
}

export async function saveArticleDraft(viewerDid: string, draft: ArticleDraft): Promise<ArticleDraft> {
  requireKey(viewerDid, draft.id);
  if (![draft.title, draft.markdown, draft.excerpt, draft.path, draft.publicationUri, draft.createdAt, draft.updatedAt].every(value => typeof value === "string") || !Array.isArray(draft.tags) || !draft.tags.every(tag => typeof tag === "string") || !Number.isFinite(Date.parse(draft.createdAt)) || !Number.isFinite(Date.parse(draft.updatedAt))) throw new Error("The article draft is invalid.");
  // Snapshot before opening storage; edits to the caller's object cannot change the queued save.
  if (draft.assets?.some(asset => !asset.id || typeof asset.alt !== "string" || typeof asset.name !== "string" || typeof asset.mimeType !== "string" || !Number.isFinite(asset.width) || !Number.isFinite(asset.height) || asset.width < 0 || asset.height < 0)) throw new Error("The article draft assets are invalid.");
  const snapshot = normalizeDraft(structuredClone(draft));
  return transaction(await openDatabase(), [DRAFTS], "readwrite", (tx, result, fail) => {
    const store = tx.objectStore(DRAFTS);
    const request = store.get([viewerDid, snapshot.id]);
    request.onsuccess = () => {
      const previous = (request.result as DraftRow | undefined)?.draft;
      if (snapshot.revision !== previous?.revision && !(snapshot.revision === 0 && !previous)) { fail(new Error("This draft changed in another tab. Reload it before saving to preserve both edits.")); return; }
      const saved = { ...snapshot, createdAt: previous?.createdAt ?? snapshot.createdAt, revision: (previous?.revision ?? 0) + 1 };
      try { store.put({ viewerDid, draftId: saved.id, draft: saved } satisfies DraftRow); result(saved); }
      catch (error) { fail(error instanceof Error ? error : new Error(String(error))); }
    };
  });
}

/** Caller confirms deletion; draft and its private assets are removed atomically. */
export async function deleteArticleDraft(viewerDid: string, draftId: string): Promise<void> {
  requireKey(viewerDid, draftId);
  return transaction(await openDatabase(), [DRAFTS, ASSETS], "readwrite", (tx, _result, fail) => {
    tx.objectStore(DRAFTS).delete([viewerDid, draftId]);
    const request = tx.objectStore(ASSETS).index("draft").openCursor([viewerDid, draftId]);
    request.onsuccess = () => {
      try { const cursor = request.result; if (cursor) { cursor.delete(); cursor.continue(); } }
      catch (error) { fail(error instanceof Error ? error : new Error(String(error))); }
    };
  });
}

/** Save the draft first; assets cannot be written into an absent or deleted draft. */
export async function saveArticleDraftAsset(viewerDid: string, draftId: string, assetId: string, blob: Blob): Promise<void> {
  requireKey(viewerDid, draftId, assetId);
  if (!(blob instanceof Blob)) throw new Error("A private draft asset must be a Blob.");
  return transaction(await openDatabase(), [DRAFTS, ASSETS], "readwrite", (tx, _result, fail) => {
    const request = tx.objectStore(DRAFTS).get([viewerDid, draftId]);
    request.onsuccess = () => {
      if (!request.result) { fail(new Error("Save the draft before adding private assets.")); return; }
      try { tx.objectStore(ASSETS).put({ viewerDid, draftId, assetId, blob } satisfies AssetRow); }
      catch (error) { fail(error instanceof Error ? error : new Error(String(error))); }
    };
  });
}

export async function getArticleDraftAsset(viewerDid: string, draftId: string, assetId: string): Promise<Blob | undefined> {
  requireKey(viewerDid, draftId, assetId);
  return transaction(await openDatabase(), [ASSETS], "readonly", (tx, result) => {
    const request = tx.objectStore(ASSETS).get([viewerDid, draftId, assetId]);
    request.onsuccess = () => result((request.result as AssetRow | undefined)?.blob);
  });
}
