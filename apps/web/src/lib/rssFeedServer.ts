/**
 * RSS / Atom parsing for server Route Handlers only (`rss-parser`).
 */

import Parser from "rss-parser";

import type { EntryDetail, EntryListItem } from "@/lib/atprotoClient";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
import {
  rssEntryIdFromParts,
  stableItemKeyFromRssItem,
} from "@/lib/rssFeedCore";

export type RssParserItemFields = {
  title?: string;
  link?: string;
  pubDate?: string;
  isoDate?: string;
  content?: string;
  contentSnippet?: string;
  guid?: unknown;
  enclosure?: { url?: string };
  itunes?: { image?: string };
};

const parser = new Parser({
  customFields: {
    item: [
      ["media:thumbnail", "mediaThumbnail", { keepArray: true }],
      ["media:content", "mediaContent", { keepArray: true }],
      ["content:encoded", "contentEncoded"],
    ],
  },
});

export type RssParserFeedOutput = Parser.Output<RssParserItemFields> &
  Record<string, unknown>;

export async function parseRssFeedXml(
  xml: string
): Promise<RssParserFeedOutput> {
  const parsed = await parser.parseString(xml);
  return parsed as unknown as RssParserFeedOutput;
}

/** Site origin for the publication (feed homepage), for favicon fallbacks and PDS `siteUrl`. */
export function feedSiteUrlFromParsed(
  parsed: RssParserFeedOutput,
  normalizedFeedUrl: string
): string | undefined {
  const link = parsed.link?.trim();
  if (link && /^https?:/i.test(link)) {
    try {
      return new URL(normalizeHttpUrlToHttps(link)).origin;
    } catch {
      /* ignore */
    }
  }
  try {
    return new URL(normalizedFeedUrl).origin;
  } catch {
    return undefined;
  }
}

/**
 * Best-effort RSS/Atom feed artwork: channel {@link Parser.Output.image},
 * Apple Podcast-style `itunes:image`, Atom `icon` when exposed by the parser.
 */
export function feedPrimaryIconUrlFromParsed(
  parsed: RssParserFeedOutput
): string | undefined {
  const asHttps = (raw: string | undefined): string | undefined => {
    const t = raw?.trim();
    if (!t || !/^https?:/i.test(t)) return undefined;
    try {
      return normalizeHttpUrlToHttps(t);
    } catch {
      return undefined;
    }
  };

  const imageUrl = parsed.image?.url?.trim();
  if (imageUrl) {
    const u = asHttps(imageUrl);
    if (u) return u;
  }

  const itunes = parsed.itunes?.image as string | { href?: string } | undefined;
  if (typeof itunes === "string") {
    const u = asHttps(itunes);
    if (u) return u;
  }
  if (itunes && typeof itunes === "object" && typeof itunes.href === "string") {
    const u = asHttps(itunes.href);
    if (u) return u;
  }

  const atomIcon = parsed.icon;
  if (typeof atomIcon === "string") {
    const u = asHttps(atomIcon);
    if (u) return u;
  }

  return undefined;
}

export function feedBrandingFromParsed(
  parsed: RssParserFeedOutput,
  normalizedFeedUrl: string
): { siteUrl?: string; feedIconUrl?: string } {
  const siteUrl = feedSiteUrlFromParsed(parsed, normalizedFeedUrl);
  const feedIconUrl = feedPrimaryIconUrlFromParsed(parsed);
  return {
    ...(siteUrl ? { siteUrl } : {}),
    ...(feedIconUrl ? { feedIconUrl } : {}),
  };
}

function publishedIsoFromItem(item: RssParserItemFields): string {
  if (item.isoDate?.trim()) return item.isoDate.trim();
  if (item.pubDate?.trim()) {
    const t = Date.parse(item.pubDate);
    if (!Number.isNaN(t)) return new Date(t).toISOString();
  }
  return new Date(0).toISOString();
}

function thumbnailFromItem(
  item: RssParserItemFields & Record<string, unknown>
): string | undefined {
  const asHttps = (raw: string | undefined): string | undefined => {
    const t = raw?.trim();
    if (!t || !/^https?:/i.test(t)) return undefined;
    try {
      return normalizeHttpUrlToHttps(t);
    } catch {
      return undefined;
    }
  };

  const mt = item.mediaThumbnail as
    | { $?: { url?: string }; url?: string }[]
    | undefined;
  const firstThumb = Array.isArray(mt) ? mt[0] : undefined;
  const mediaThumb = asHttps(firstThumb?.$?.url ?? firstThumb?.url);
  if (mediaThumb) return mediaThumb;

  const mc = item.mediaContent as
    | { $?: { url?: string; type?: string; medium?: string }; url?: string; type?: string; medium?: string }[]
    | undefined;
  const firstContent = Array.isArray(mc) ? mc[0] : undefined;
  const mediaContentUrl = asHttps(firstContent?.$?.url ?? firstContent?.url);
  const mediaContentType = firstContent?.$?.type ?? firstContent?.type;
  const mediaContentMedium = firstContent?.$?.medium ?? firstContent?.medium;
  if (
    mediaContentUrl &&
    acceptsMediaThumbnailUrl(mediaContentUrl, mediaContentType, mediaContentMedium)
  ) {
    return mediaContentUrl;
  }

  const enc = item.enclosure?.url;
  const encType = (item.enclosure as { type?: string } | undefined)?.type;
  if (enc && acceptsMediaThumbnailUrl(enc, encType, undefined)) {
    return asHttps(enc);
  }

  const itunesImg = item.itunes?.image;
  if (typeof itunesImg === "string") {
    const u = asHttps(itunesImg);
    if (u) return u;
  }

  const html =
    item.content?.trim() ||
    (item as { contentEncoded?: string }).contentEncoded?.trim() ||
    item.contentSnippet?.trim() ||
    "";
  const fromHtml = firstImageUrlFromHtml(html, item.link?.trim());
  if (fromHtml) return fromHtml;

  return undefined;
}

function acceptsMediaThumbnailUrl(
  url: string,
  type: string | undefined,
  medium: string | undefined
): boolean {
  const typeLower = type?.trim().toLowerCase();
  if (typeLower?.startsWith("image/")) return true;
  if (medium?.trim().toLowerCase() === "image") return true;
  if (!typeLower && !medium?.trim()) {
    try {
      const path = new URL(url).pathname.toLowerCase();
      return [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg"].some(
        (ext) => path.endsWith(ext) || path.includes(`${ext}?`)
      );
    } catch {
      return false;
    }
  }
  return false;
}

function firstImageUrlFromHtml(html: string, base?: string): string | undefined {
  if (!html) return undefined;
  const imgMatch =
    html.match(/<img\b[^>]*\bsrc=["']([^"']+)["']/i) ??
    html.match(/<img\b[^>]*\bsrc=([^\s>]+)/i);
  const raw = imgMatch?.[1]?.trim();
  if (!raw) return undefined;
  try {
    const resolved = base ? new URL(raw, base).href : raw;
    if (!/^https?:/i.test(resolved)) return undefined;
    return normalizeHttpUrlToHttps(resolved);
  } catch {
    return undefined;
  }
}

function escapeHtmlText(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function htmlBodyFromItem(item: RssParserItemFields): string {
  const raw =
    item.content?.trim() ||
    (item as { contentEncoded?: string }).contentEncoded?.trim() ||
    "";
  if (raw) return raw;
  const snippet = item.contentSnippet?.trim() || "";
  if (snippet) return `<p>${escapeHtmlText(snippet)}</p>`;
  return "<p></p>";
}

export function rssParserItemToListItem(
  normalizedFeedUrl: string,
  item: RssParserItemFields & Record<string, unknown>
): EntryListItem {
  const stable = stableItemKeyFromRssItem({
    guid: item.guid,
    link: item.link,
    title: item.title,
    isoDate: item.isoDate,
  });
  const entryId = rssEntryIdFromParts(normalizedFeedUrl, stable);
  const pubAt = publishedIsoFromItem(item);
  const thumb = thumbnailFromItem(item);
  const summary =
    item.contentSnippet?.trim() ||
    item.title?.trim() ||
    item.link?.trim();
  return {
    entryId,
    title: item.title?.trim() || item.link?.trim() || "Untitled",
    ...(summary && summary !== (item.title?.trim() || "")
      ? { summary }
      : {}),
    publishedAt: pubAt,
    ...(thumb ? { thumbnailUrl: thumb } : {}),
  };
}

export function rssParserItemToDetail(
  normalizedFeedUrl: string,
  item: RssParserItemFields & Record<string, unknown>
): EntryDetail {
  const list = rssParserItemToListItem(normalizedFeedUrl, item);
  const link = item.link?.trim();
  const orig = link ? normalizeHttpUrlToHttps(link) : undefined;
  const body = htmlBodyFromItem(item);
  return {
    entryId: list.entryId,
    title: list.title,
    publishedAt: list.publishedAt,
    contentHtml: body,
    ...(orig ? { originalUrl: orig } : {}),
    ...(orig ? { embedUrl: orig } : {}),
  };
}

export async function rssItemsSortedNewestFirst(
  xml: string
): Promise<Array<RssParserItemFields & Record<string, unknown>>> {
  const parsed = await parseRssFeedXml(xml);
  const items = (parsed.items ?? []) as Array<
    RssParserItemFields & Record<string, unknown>
  >;
  return [...items].sort((a, b) =>
    publishedIsoFromItem(b).localeCompare(publishedIsoFromItem(a))
  );
}

export function pickRssParserItemByStableKey(
  items: Array<RssParserItemFields & Record<string, unknown>>,
  wantKey: string
): (RssParserItemFields & Record<string, unknown>) | null {
  for (const it of items) {
    const k = stableItemKeyFromRssItem({
      guid: it.guid,
      link: it.link,
      title: it.title,
      isoDate: it.isoDate,
    });
    if (k === wantKey) return it;
  }
  return null;
}
