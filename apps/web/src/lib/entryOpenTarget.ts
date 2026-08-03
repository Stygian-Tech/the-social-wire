import type { EntryListItem } from "@/lib/atprotoClient";
import type { RssArticleOpenMode } from "@/lib/feedPreferences";
import { isRssEntryId } from "@/lib/rssFeedCore";

export type EntryOpenTarget =
  | { kind: "external"; url: string }
  | { kind: "rssReader"; url: string };

export function entryOpenTarget(
  entry: Pick<EntryListItem, "entryId" | "originalUrl">,
  rssArticleOpenMode: RssArticleOpenMode = "reader",
): EntryOpenTarget | null {
  const rawUrl = entry.originalUrl?.trim();
  if (!rawUrl) return null;

  let url: URL;
  try {
    if (rawUrl.startsWith("/") && !rawUrl.startsWith("//")) {
      url = new URL(
        rawUrl,
        typeof window === "undefined"
          ? "http://localhost"
          : window.location.origin,
      );
    } else {
      url = new URL(rawUrl);
    }
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;

  const useRssReader =
    isRssEntryId(entry.entryId) && rssArticleOpenMode === "reader";
  return { kind: useRssReader ? "rssReader" : "external", url: url.href };
}
