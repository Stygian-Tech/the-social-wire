import type { PodcastShow } from "./client";

function normalizedFeedUrl(raw: unknown): string | null {
  if (typeof raw !== "string" || !raw.trim()) return null;
  try {
    const value = raw.trim();
    const url = new URL(/^https?:\/\//i.test(value) ? value : `https://${value}`);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    url.protocol = "https:";
    url.hash = "";
    url.username = "";
    url.password = "";
    return url.href.replace(/\/$/, "");
  } catch {
    return null;
  }
}

export function podcastSubscriptionMatchesShow(record: Record<string, unknown>, show: PodcastShow, key: string | undefined, canonicalKey: string): boolean {
  const category = typeof record.category === "string" ? record.category.trim().toLowerCase() : "";
  const native = typeof record.externalRef === "string" && /^at:\/\/[^/]+\/(org\.atpodcasting\.podcast|place\.pod\.show|live\.voxport\.podcast\.series)\/[^/]+$/.test(record.externalRef);
  const sourceType = typeof record.sourceType === "string" ? record.sourceType.trim().toLowerCase() : "";
  if (category ? category !== "podcast" : sourceType !== "atproto.collection" || !native) return false;
  const feed = normalizedFeedUrl(show.feedUrl);
  return key === canonicalKey
    || (feed !== null && normalizedFeedUrl(record.feedUrl) === feed)
    || (!!show.sourceUri && record.externalRef === show.sourceUri);
}
