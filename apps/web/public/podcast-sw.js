/* Podcast shell and viewer-scoped offline media. Never caches authenticated API responses. */
const SHELL = "the-social-wire.podcast-shell.v1";
self.addEventListener("install", (event) => {
  event.waitUntil(self.skipWaiting());
});
self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});
function openDownloads() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("the-social-wire.podcast-downloads.v1", 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("downloads");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function offlineMedia(request, url) {
  const viewer = url.searchParams.get("viewer");
  const episode = url.searchParams.get("episodeId");
  if (!viewer?.startsWith("did:") || !episode)
    return new Response("Missing Download", { status: 404 });
  const db = await openDownloads();
  let download;
  try {
    download = await new Promise((resolve, reject) => {
      const read = db
        .transaction("downloads")
        .objectStore("downloads")
        .get(`${viewer}\n${episode}`);
      read.onsuccess = () => resolve(read.result);
      read.onerror = () => reject(read.error);
    });
  } finally {
    db.close();
  }
  const media = download?.media;
  if (!(media instanceof Blob))
    return new Response("Download Was Evicted", { status: 404 });
  const headers = {
    "Content-Type": media.type || "audio/mpeg",
    "Accept-Ranges": "bytes",
    "Cache-Control": "no-store",
  };
  const range = request.headers.get("Range");
  if (!range)
    return new Response(request.method === "HEAD" ? null : media, {
      headers: { ...headers, "Content-Length": String(media.size) },
    });
  const match = /^bytes=(\d*)-(\d*)$/.exec(range);
  if (!match || (!match[1] && !match[2]))
    return new Response(null, {
      status: 416,
      headers: { "Content-Range": `bytes */${media.size}` },
    });
  const start = match[1]
    ? Number(match[1])
    : Math.max(0, media.size - Number(match[2]));
  const end =
    match[1] && match[2]
      ? Math.min(Number(match[2]), media.size - 1)
      : media.size - 1;
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    start < 0 ||
    start > end ||
    start >= media.size
  )
    return new Response(null, {
      status: 416,
      headers: { "Content-Range": `bytes */${media.size}` },
    });
  return new Response(
    request.method === "HEAD" ? null : media.slice(start, end + 1),
    {
      status: 206,
      headers: {
        ...headers,
        "Content-Range": `bytes ${start}-${end}/${media.size}`,
        "Content-Length": String(end - start + 1),
      },
    },
  );
}
self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname === "/podcasts/offline-media") {
    event.respondWith(offlineMedia(request, url));
    return;
  }
  if (request.method !== "GET") return;
  if (request.mode === "navigate" && url.pathname === "/podcasts") {
    event.respondWith(
      fetch(request)
        .then(async (response) => {
          if (response.ok) {
            const cache = await caches.open(SHELL);
            await cache.put("/podcasts", response.clone());
          }
          return response;
        })
        .catch(
          async () =>
            (await caches.match("/podcasts")) ||
            new Response(
              "Open Podcasts online once to save its offline shell.",
              { status: 503 },
            ),
        ),
    );
  } else if (
    url.pathname.startsWith("/_next/static/") ||
    url.pathname.startsWith("/fonts/")
  ) {
    event.respondWith(
      caches.match(request).then(
        (cached) =>
          cached ||
          fetch(request).then(async (response) => {
            if (response.ok) {
              const cache = await caches.open(SHELL);
              await cache.put(request, response.clone());
            }
            return response;
          }),
      ),
    );
  }
});
