import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

import { validateHttpsEmbedProbeTarget } from "@/lib/embedFramePolicy";
import {
  extractOEmbedEndpointFromHtml,
  isUsableOEmbedResponse,
  oEmbedRequestUrl,
  parseOEmbedJson,
  wordPressOEmbedEndpoint,
  type OEmbedResponse,
} from "@/lib/oEmbed";

const TIMEOUT_MS = 8_000;

const FETCH_INIT = {
  redirect: "follow" as const,
  signal: AbortSignal.timeout(TIMEOUT_MS),
  headers: {
    "User-Agent": "the-social-wire/oembed",
    Accept: "text/html,application/json,*/*",
  },
};

async function fetchPageHtml(pageHref: string): Promise<string | null> {
  try {
    const res = await fetch(pageHref, { ...FETCH_INIT, method: "GET" });
    if (!res.ok) return null;
    const ct = res.headers.get("content-type") ?? "";
    if (!/text\/html/i.test(ct)) return null;
    const text = await res.text();
    return text.slice(0, 512_000);
  } catch {
    return null;
  }
}

async function fetchOEmbedFromEndpoint(
  endpoint: string,
  pageHref: string
): Promise<OEmbedResponse | null> {
  try {
    const res = await fetch(oEmbedRequestUrl(endpoint, pageHref), {
      ...FETCH_INIT,
      method: "GET",
      headers: {
        ...FETCH_INIT.headers,
        Accept: "application/json",
      },
    });
    if (!res.ok) return null;
    const json: unknown = await res.json();
    return parseOEmbedJson(json);
  } catch {
    return null;
  }
}

async function resolveOEmbed(pageHref: string): Promise<OEmbedResponse | null> {
  const html = await fetchPageHtml(pageHref);
  const endpoints: string[] = [];

  if (html) {
    const discovered = extractOEmbedEndpointFromHtml(html);
    if (discovered) endpoints.push(discovered);
  }

  try {
    endpoints.push(wordPressOEmbedEndpoint(new URL(pageHref).origin));
  } catch {
    // ignore
  }

  const seen = new Set<string>();
  for (const endpoint of endpoints) {
    if (seen.has(endpoint)) continue;
    seen.add(endpoint);
    const oembed = await fetchOEmbedFromEndpoint(endpoint, pageHref);
    if (oembed && isUsableOEmbedResponse(oembed)) {
      return oembed;
    }
  }

  return null;
}

export async function GET(req: NextRequest) {
  const encoded = req.nextUrl.searchParams.get("url");
  if (encoded == null || encoded === "") {
    return NextResponse.json({ error: "missing url" }, { status: 400 });
  }

  let decoded: string;
  try {
    decoded = decodeURIComponent(encoded);
  } catch {
    return NextResponse.json({ error: "invalid url encoding" }, { status: 400 });
  }

  const validated = validateHttpsEmbedProbeTarget(decoded);
  if (!validated.ok) {
    return NextResponse.json({ error: "invalid url" }, { status: 400 });
  }

  try {
    const oembed = await resolveOEmbed(validated.url.href);
    if (!oembed) {
      return NextResponse.json({ ok: false, reason: "not_found" });
    }
    return NextResponse.json({
      ok: true,
      oembed,
      canonicalUrl: validated.url.href,
    });
  } catch {
    return NextResponse.json({ ok: false, reason: "fetch_failed" });
  }
}
