import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";
import {
  normalizeRssFeedUrlInput,
  validateRssFeedFetchUrl,
} from "@/lib/rssFeedCore";
import {
  feedBrandingFromParsed,
  parseRssFeedXml,
} from "@/lib/rssFeedServer";

export const runtime = "nodejs";

const FETCH_TIMEOUT_MS = 12_000;

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
  const rawUrl = req.nextUrl.searchParams.get("url")?.trim();
  if (!rawUrl) {
    return NextResponse.json({ error: "missing url" }, { status: 400 });
  }

  const normalizedStored = normalizeRssFeedUrlInput(rawUrl);
  const validFeed = validateRssFeedFetchUrl(normalizedStored);
  if (!validFeed.ok) {
    return NextResponse.json({ error: validFeed.reason }, { status: 400 });
  }

  if (req.nextUrl.searchParams.get("brandingOnly") !== "1") {
    return NextResponse.json(
      { error: "brandingOnly=1 is required" },
      { status: 400 }
    );
  }

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
