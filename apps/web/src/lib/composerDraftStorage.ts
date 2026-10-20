import type { ThreadPublication, ThreadSegment } from "./blueskyThreadClient";
import type { AppBskyDraftDefs } from "@atproto/api";
import { jsonToLex, stringifyLex } from "@atproto/api";

export type ComposerDraft = { version: 1; did: string; segments: ThreadSegment[]; publication?: ThreadPublication; cloud?: {
  id?: string;
  deviceId: string;
  updatedAt: number;
  nativeDraft?: AppBskyDraftDefs.Draft;
  acknowledged?: AppBskyDraftDefs.Draft;
  stalePayloads?: string[];
  createIntent?: { draft: AppBskyDraftDefs.Draft; baselineIds: string[] };
  completed?: boolean;
  cleaned?: boolean;
  conflictCopyContext?: string;
  pendingUpdate?: { draft: AppBskyDraftDefs.Draft; previous?: AppBskyDraftDefs.Draft };
  forkSource?: { id: string; draft: AppBskyDraftDefs.Draft };
} };
let database: Promise<IDBDatabase> | undefined;
const queues = new Map<string, Promise<unknown>>();

function open(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") return Promise.reject(new Error("Draft Storage Is Unavailable"));
  if (!database) database = new Promise((resolve, reject) => {
    const request = indexedDB.open("the-social-wire.composer.v1", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("drafts");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => { database = undefined; reject(request.error); };
  });
  return database;
}

export async function loadComposerDraft(did: string, context: string): Promise<ComposerDraft | undefined> {
  const key = `${did}:${context}`;
  await queues.get(key)?.catch(() => {});
  const db = await open();
  return new Promise((resolve, reject) => {
    const request = db.transaction("drafts").objectStore("drafts").get(key);
    request.onsuccess = () => {
      try {
      const value = request.result as ComposerDraft | undefined;
      if (value && (value.version !== 1 || value.did !== did || !Array.isArray(value.segments) || !value.segments.length)) { reject(new Error("Saved Draft Is Incompatible")); return; }
      if (value) for (const segment of value.segments) { if (segment.media?.kind === "photos") segment.media.photos = segment.media.photos.map(photo => photo.status === "preparing" ? { ...photo, status: "failed", error: "Photo Preparation Was Interrupted. Retry." } : photo); }
      if (value?.publication) for (const segment of value.publication.segments) { if (segment.record) segment.record = jsonToLex(segment.record) as typeof segment.record; }
      if (value) for (const segment of value.segments) { if (segment.replyTo) segment.replyTo = jsonToLex(segment.replyTo) as typeof segment.replyTo; if (segment.quoteTo) segment.quoteTo = jsonToLex(segment.quoteTo) as typeof segment.quoteTo; }
      resolve(value);
      } catch (error) { reject(error); }
    };
    request.onerror = () => reject(request.error);
  });
}

/** Queue snapshots so an older autosave cannot overwrite a newer publication checkpoint. */
export function saveComposerDraft(did: string, context: string, draft?: ComposerDraft): Promise<void> {
  const key = `${did}:${context}`;
  // ATProto BlobRefs/CIDs need lexicon JSON; structuredClone alone loses their
  // prototypes, making a restored record serialize differently on a safe retry.
  const plainSegment = (segment: ThreadSegment) => ({ ...segment, ...(segment.replyTo ? { replyTo: JSON.parse(stringifyLex(segment.replyTo)) } : {}), ...(segment.quoteTo ? { quoteTo: JSON.parse(stringifyLex(segment.quoteTo)) } : {}) });
  const snapshot = draft ? structuredClone({ ...draft, segments: draft.segments.map(plainSegment), ...(draft.publication ? { publication: { ...draft.publication, segments: draft.publication.segments.map(segment => ({ ...segment, draft: plainSegment(segment.draft), ...(segment.record ? { record: JSON.parse(stringifyLex(segment.record)) } : {}) })) } } : {}) }) : undefined;
  const work = (queues.get(key) ?? Promise.resolve()).catch(() => {}).then(async () => {
    const db = await open();
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction("drafts", "readwrite");
      if (snapshot) transaction.objectStore("drafts").put(snapshot, key);
      else transaction.objectStore("drafts").delete(key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = transaction.onabort = () => reject(transaction.error ?? new Error("Draft Could Not Be Saved"));
    });
  });
  queues.set(key, work);
  return work;
}
