import { socialHttpsUrl } from "./socialUrls";

/** Build player URLs from video IDs only, never from arbitrary external iframe URLs. */
export function socialYouTubePlayerUrl(value: string): string | undefined {
  const href = socialHttpsUrl(value);
  if (!href) return undefined;
  const url = new URL(href);
  if (url.port) return undefined;
  const host = url.hostname;
  let id: string | null | undefined;
  if (host === "youtu.be") id = /^\/([^/]+)\/?$/.exec(url.pathname)?.[1];
  else if (["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].includes(host)) {
    if (url.pathname === "/watch") id = url.searchParams.get("v");
    else id = /^\/(?:shorts|live|embed)\/([^/]+)\/?$/.exec(url.pathname)?.[1];
  }
  if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return undefined;
  const embed = new URL(`https://www.youtube-nocookie.com/embed/${id}`);
  const time = url.searchParams.get("start") ?? url.searchParams.get("t");
  if (time) {
    const match = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/.exec(time);
    const start = /^\d+$/.test(time) ? Number(time) : match ? Number(match[1] ?? 0) * 3600 + Number(match[2] ?? 0) * 60 + Number(match[3] ?? 0) : 0;
    if (Number.isSafeInteger(start) && start > 0) embed.searchParams.set("start", String(start));
  }
  return embed.href;
}
