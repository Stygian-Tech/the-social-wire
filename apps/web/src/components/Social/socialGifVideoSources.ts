import { socialHttpsUrl } from "./socialUrls";

/** Rendition filenames travel in the published URI; never infer them by extension replacement. */
export function socialGifVideoSources(raw: string): { mp4?: string; webm?: string } {
  const safe = socialHttpsUrl(raw);
  if (!safe) return {};
  const url = new URL(safe);
  if (url.hostname !== "static.klipy.com" || !url.pathname.startsWith("/ii/")) return {};
  const sources: { mp4?: string; webm?: string } = {};
  for (const format of ["mp4", "webm"] as const) {
    const slug = url.searchParams.get(format);
    if (!slug || !/^[A-Za-z0-9_-]{1,200}$/.test(slug)) continue;
    const video = new URL(url);
    video.pathname = url.pathname.slice(0, url.pathname.lastIndexOf("/") + 1) + `${slug}.${format}`;
    for (const parameter of ["hh", "ww", "mp4", "webm"]) video.searchParams.delete(parameter);
    sources[format] = video.href;
  }
  return sources;
}
