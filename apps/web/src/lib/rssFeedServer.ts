/**
 * RSS / Atom parsing for server Route Handlers only (`rss-parser`).
 */

import Parser from "rss-parser";

import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

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
