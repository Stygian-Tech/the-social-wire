import type {
  PodcastEpisode,
  PodcastTranscript,
  PodcastSilence,
} from "./client";
export type PodcastDownload = {
  episode: PodcastEpisode;
  bytes: number;
  downloadedAt: string;
  transcript?: PodcastTranscript;
  transcripts?: PodcastTranscript[];
  silence?: PodcastSilence;
};
const database = "the-social-wire.podcast-downloads.v1";
function openStore(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(database, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("downloads");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function operation<T>(
  mode: IDBTransactionMode,
  run: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await openStore();
  try {
    return await new Promise<T>((resolve, reject) => {
      const transaction = db.transaction("downloads", mode);
      const request = run(transaction.objectStore("downloads"));
      let result: T;
      request.onsuccess = () => {
        result = request.result;
      };
      transaction.oncomplete = () => resolve(result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () =>
        reject(
          transaction.error ??
            new Error("Download storage transaction aborted"),
        );
    });
  } finally {
    db.close();
  }
}
const key = (viewer: string, episodeID: string) => `${viewer}\n${episodeID}`;
export async function savePodcastDownload(
  viewer: string,
  download: PodcastDownload,
  media: Blob,
): Promise<void> {
  if (!viewer.startsWith("did:"))
    throw new Error("Sign in to download a podcast");
  await operation("readwrite", (store) =>
    store.put({ ...download, viewer, media }, key(viewer, download.episode.id)),
  );
}
export async function getPodcastDownload(
  viewer: string,
  episodeID: string,
): Promise<(PodcastDownload & { media: Blob }) | undefined> {
  return operation("readonly", (store) => store.get(key(viewer, episodeID)));
}
export async function listPodcastDownloads(
  viewer: string,
): Promise<PodcastDownload[]> {
  const all = await operation<
    (PodcastDownload & { viewer: string; media: Blob })[]
  >("readonly", (store) => store.getAll());
  return all
    .filter((item) => item.viewer === viewer && item.media instanceof Blob)
    .map((item) => ({
      episode: item.episode,
      bytes: item.bytes,
      downloadedAt: item.downloadedAt,
      transcript: item.transcript,
      transcripts: item.transcripts,
      silence: item.silence,
    }));
}
export async function deletePodcastDownload(
  viewer: string,
  episodeID: string,
): Promise<void> {
  await operation("readwrite", (store) => store.delete(key(viewer, episodeID)));
}
export async function clearPodcastViewerDownloads(
  viewer: string,
): Promise<void> {
  for (const item of await listPodcastDownloads(viewer))
    await deletePodcastDownload(viewer, item.episode.id);
}
export async function registerPodcastOfflineShell(): Promise<void> {
  if (!("serviceWorker" in navigator)) return;
  await navigator.serviceWorker.register("/podcast-sw.js", {
    scope: "/podcasts",
  });
  await navigator.storage?.persist?.();
  // Registration occurs after the initial document load. Explicitly prime that first offline visit.
  const cache = await caches.open("the-social-wire.podcast-shell.v1");
  const shell = await fetch("/podcasts", { headers: { Accept: "text/html" } });
  if (shell.ok) await cache.put("/podcasts", shell);
  const assets = [
    ...document.querySelectorAll<HTMLScriptElement | HTMLLinkElement>(
      "script[src], link[rel=stylesheet]",
    ),
  ]
    .map((element) =>
      element instanceof HTMLScriptElement ? element.src : element.href,
    )
    .filter((url) => new URL(url).pathname.startsWith("/_next/static/"));
  await Promise.allSettled(
    assets.map(async (url) => {
      const response = await fetch(url);
      if (response.ok) await cache.put(url, response);
    }),
  );
}
