import type { AppBskyDraftDefs } from "@atproto/api";

export type PendingDraftDeletion = { ownerDid: string; draft: AppBskyDraftDefs.DraftView };

async function open(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") throw new Error("Draft Recovery Storage Is Unavailable.");
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("the-social-wire.social-draft-deletions.v1", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("pending", { keyPath: ["ownerDid", "draft.id"] }).createIndex("owner", "ownerDid");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

/** Keep deletion work discoverable after the native draft disappears from its list. */
export async function pendingDraftDeletions(ownerDid: string): Promise<PendingDraftDeletion[]> {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const request = db.transaction("pending").objectStore("pending").index("owner").getAll(ownerDid);
      request.onsuccess = () => resolve(request.result as PendingDraftDeletion[]);
      request.onerror = () => reject(request.error);
    });
  } finally { db.close(); }
}

export async function saveDraftDeletion(ownerDid: string, draft: AppBskyDraftDefs.DraftView, completed = false): Promise<void> {
  const db = await open();
  try {
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction("pending", "readwrite");
      const store = transaction.objectStore("pending");
      if (completed) store.delete([ownerDid, draft.id]);
      else store.put({ ownerDid, draft: structuredClone(draft) });
      transaction.oncomplete = () => resolve();
      transaction.onerror = transaction.onabort = () => reject(transaction.error ?? new Error("Draft Deletion Recovery Could Not Be Saved."));
    });
  } finally { db.close(); }
}
