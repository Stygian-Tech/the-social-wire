import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";
import type { EntryDetail, EntryListItem } from "@/lib/atprotoClient";
import {
  normalizeRssFeedUrlInput,
  validateRssFeedFetchUrl,
  isRssEntryId,
  rssEntryIdDecode,
} from "@/lib/rssFeedCore";
import {
  feedBrandingFromParsed,
  parseRssFeedXml,
  rssParserItemToDetail,
  rssParserItemToListItem,
  pickRssParserItemByStableKey,
  rssItemsSortedNewestFirst,
} from "@/lib/rssFeedServer";

export const runtime = "nodejs";

const FETCH_TIMEOUT_MS = 12_000;
const DEFAULT_LIMIT = 30;
const MAX_LIMIT = 100;

async function fetchFeedXml(href: string): Promise<string> {
  const init = {
    redirect: "follow" as const,
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    headers: {
      "User-Agent": "the-social-wire/rss-fetch",
      Accept:
        "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, text/html;q=0.7, */*;q=0.5",
    },
  };

  const res = await fetch(href, init);
  if (
    !res.ok &&
    res.status !== 406 &&
    res.status !== 403 &&
    res.status !== 415
  ) {
    throw new Error(`Feed request failed (${res.status})`);
  }
  return (await res.text()) ?? "";
}

export async function GET(req: NextRequest) {
  const entryIdParam =
    req.nextUrl.searchParams.get("entryId")?.trim() ||
    req.nextUrl.searchParams.get("entry")?.trim();

  if (entryIdParam && isRssEntryId(entryIdParam)) {
    const decoded = rssEntryIdDecode(entryIdParam);
    if (!decoded) {
      return NextResponse.json({ error: "invalid entry id" }, { status: 400 });
    }
    const normalized = normalizeRssFeedUrlInput(decoded.feedUrl);
    const validFeed = validateRssFeedFetchUrl(normalized);
    if (!validFeed.ok) {
      return NextResponse.json({ error: validFeed.reason }, { status: 400 });
    }
    try {
      const xml = await fetchFeedXml(validFeed.url.href);
      const items = await rssItemsSortedNewestFirst(xml);
      const match = pickRssParserItemByStableKey(items, decoded.itemKey);

      if (!match) {
        return NextResponse.json({ error: "entry not found" }, { status: 404 });
      }

      const entry: EntryDetail = rssParserItemToDetail(normalized, match);
      return NextResponse.json({ entry, normalizedUrl: normalized });
    } catch {
      return NextResponse.json({ error: "failed to fetch feed" }, { status: 502 });
    }
  }

  const rawUrl = req.nextUrl.searchParams.get("url")?.trim();
  if (!rawUrl) {
    return NextResponse.json({ error: "missing url" }, { status: 400 });
  }

  const normalizedStored = normalizeRssFeedUrlInput(rawUrl);
  const validFeed = validateRssFeedFetchUrl(normalizedStored);
  if (!validFeed.ok) {
    return NextResponse.json({ error: validFeed.reason }, { status: 400 });
  }

  const brandingOnly = req.nextUrl.searchParams.get("brandingOnly") === "1";
  if (brandingOnly) {
    try {
      const xml = await fetchFeedXml(validFeed.url.href);
      const parsed = await parseRssFeedXml(xml);
      const branding = feedBrandingFromParsed(parsed, normalizedStored);
      let faviconFallbackUrl: string | undefined;
      try {
        faviconFallbackUrl = `${new URL(normalizedStored).origin}/favicon.ico`;
      } catch {
        faviconFallbackUrl = undefined;
      }
      return NextResponse.json({
        normalizedUrl: normalizedStored,
        ...branding,
        ...(faviconFallbackUrl ? { faviconFallbackUrl } : {}),
      });
    } catch {
      return NextResponse.json({ error: "failed to fetch feed" }, { status: 502 });
    }
  }

  const rawLimit = req.nextUrl.searchParams.get("limit");
  let limit = DEFAULT_LIMIT;
  if (rawLimit !== null && rawLimit !== "") {
    const n = Number.parseInt(rawLimit, 10);
    if (Number.isFinite(n) && n >= 1) limit = Math.min(MAX_LIMIT, n);
  }

  const rawCursor = req.nextUrl.searchParams.get("cursor");
  let offset = 0;
  if (rawCursor !== null && rawCursor !== "") {
    const n = Number.parseInt(rawCursor, 10);
    if (Number.isFinite(n) && n >= 0) offset = Math.min(n, 1_000_000);
  }

  try {
    const xml = await fetchFeedXml(validFeed.url.href);
    const items = await rssItemsSortedNewestFirst(xml);

    const page: EntryListItem[] = items
      .slice(offset, offset + limit)
      .map((it) => rssParserItemToListItem(normalizedStored, it));

    const nextOffset = offset + page.length;
    const nextCursor =
      nextOffset < items.length ? String(nextOffset) : undefined;

    const payload: {
      items: EntryListItem[];
      normalizedUrl: string;
      nextCursor?: string;
    } = {
      items: page,
      normalizedUrl: normalizedStored,
    };
    if (nextCursor !== undefined) payload.nextCursor = nextCursor;

    return NextResponse.json(payload);
  } catch {
    return NextResponse.json({ error: "failed to fetch feed" }, { status: 502 });
  }
}
