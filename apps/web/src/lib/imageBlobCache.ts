import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

const DB_NAME = "the-social-wire.image-cache.v1";
const STORE = "images";
const DB_VERSION = 1;
const MAX_ENTRIES = 400;
const MAX_AGE_MS = 1000 * 60 * 60 * 24 * 7;

type CachedImageRow = {
  url: string;
  blob: Blob;
  storedAt: number;
  contentType: string;
};

let dbPromise: Promise<IDBDatabase> | null = null;

function openImageCacheDb(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") {
    return Promise.reject(new Error("IndexedDB unavailable"));
  }
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE)) {
          db.createObjectStore(STORE, { keyPath: "url" });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error ?? new Error("IndexedDB open failed"));
    });
  }
  return dbPromise;
}

async function readCachedBlob(url: string): Promise<Blob | null> {
  try {
    const db = await openImageCacheDb();
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const store = tx.objectStore(STORE);
      const req = store.get(url);
      req.onsuccess = () => {
        const row = req.result as CachedImageRow | undefined;
        if (!row?.blob) {
          resolve(null);
          return;
        }
        if (Date.now() - row.storedAt > MAX_AGE_MS) {
          resolve(null);
          return;
        }
        resolve(row.blob);
      };
      req.onerror = () => reject(req.error ?? new Error("IndexedDB read failed"));
    });
  } catch {
    return null;
  }
}

async function writeCachedBlob(url: string, blob: Blob): Promise<void> {
  try {
    const db = await openImageCacheDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      const store = tx.objectStore(STORE);
      store.put({
        url,
        blob,
        storedAt: Date.now(),
        contentType: blob.type || "application/octet-stream",
      } satisfies CachedImageRow);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error ?? new Error("IndexedDB write failed"));
    });
    await trimImageCache();
  } catch {
    /* best-effort cache */
  }
}

async function trimImageCache(): Promise<void> {
  try {
    const db = await openImageCacheDb();
    const rows = await new Promise<CachedImageRow[]>((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const store = tx.objectStore(STORE);
      const req = store.getAll();
      req.onsuccess = () => resolve((req.result as CachedImageRow[]) ?? []);
      req.onerror = () => reject(req.error ?? new Error("IndexedDB read failed"));
    });
    if (rows.length <= MAX_ENTRIES) return;
    rows.sort((a, b) => a.storedAt - b.storedAt);
    const toDelete = rows.slice(0, rows.length - MAX_ENTRIES);
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      const store = tx.objectStore(STORE);
      for (const row of toDelete) {
        store.delete(row.url);
      }
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error ?? new Error("IndexedDB trim failed"));
    });
  } catch {
    /* ignore */
  }
}

function normalizeImageCacheKey(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  return normalizeHttpUrlToHttps(trimmed);
}

/**
 * Returns a blob object URL for `rawUrl`, using IndexedDB when available.
 * Caller must revoke the URL when the consumer unmounts.
 */
export async function fetchCachedImageObjectUrl(
  rawUrl: string,
  signal?: AbortSignal
): Promise<string | undefined> {
  const url = normalizeImageCacheKey(rawUrl);
  if (!url) return undefined;

  const cached = await readCachedBlob(url);
  if (cached) {
    return URL.createObjectURL(cached);
  }

  const res = await fetch(url, {
    signal,
    referrerPolicy: "no-referrer",
    cache: "force-cache",
  });
  if (!res.ok) return undefined;

  const blob = await res.blob();
  if (blob.size === 0) return undefined;

  void writeCachedBlob(url, blob);
  return URL.createObjectURL(blob);
}

/** Warm the image cache without blocking UI (icons/thumbs after sidebar/feed load). */
export function prefetchCachedImages(urls: Iterable<string | null | undefined>): void {
  for (const raw of urls) {
    if (!raw?.trim()) continue;
    void fetchCachedImageObjectUrl(raw).then((objectUrl) => {
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    });
  }
}
