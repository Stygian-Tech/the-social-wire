/** Recover the publisher's original when a Transistor image CDN request fails. */
export function podcastArtworkFallback(source: string): string | undefined {
  try {
    const url = new URL(source);
    if (url.protocol !== "https:" || url.hostname !== "img.transistorcdn.com" || url.username || url.password || url.port) return;
    const parts = url.pathname.split("/");
    const start = parts.findIndex(part => part.startsWith("aHR0cHM6Ly"));
    if (start < 0) return;
    const encoded = parts.slice(start).join("").replace(/\.(?:jpg|jpeg|png|webp)$/i, "").replace(/-/g, "+").replace(/_/g, "/");
    const original = new URL(atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "=")));
    const publisherImage = original.pathname.startsWith("/show/") || /^\/[a-f0-9]{32}\.(?:jpg|jpeg|png|webp)$/i.test(original.pathname);
    if (original.protocol !== "https:" || original.hostname !== "img-upload-production.transistor.fm" || original.username || original.password || original.port || original.hash || original.search || !publisherImage) return;
    return original.href;
  } catch {
    return;
  }
}
