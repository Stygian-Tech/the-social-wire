/**
 * Server-only: resolve pasted URL / handle / AT-URI into a subscription target
 * (standard.site publication AT-URI vs RSS feed URL). Used by the resolve-add-publication API.
 */

import {
  fetchPublicationRecordValue,
  normalizeAtRepoParam,
  parseAtUri,
  PUBLICATION_RECORD_COLLECTIONS,
  probeFirstPublicationRecordUri,
} from "@/lib/atprotoClient";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
import {
  normalizeRssFeedUrlInput,
  validateRssFeedFetchUrl,
} from "@/lib/rssFeedCore";
import {
  parseRssFeedXml,
  rssItemsSortedNewestFirst,
  feedBrandingFromParsed,
} from "@/lib/rssFeedServer";

export const RESOLVE_PUBLICATION_FETCH_MS = 14_000;

const USER_AGENT = "the-social-wire/resolve-publication";

async function fetchText(url: string, signal?: AbortSignal): Promise<Response> {
  return fetch(url, {
    redirect: "follow" as const,
    signal: signal ?? AbortSignal.timeout(RESOLVE_PUBLICATION_FETCH_MS),
    headers: {
      "User-Agent": USER_AGENT,
      Accept:
        "text/html,application/xhtml+xml,application/xml;q=0.9,application/rss+xml,application/atom+xml;q=0.9,text/xml;q=0.8,*/*;q=0.5",
    },
  });
}

function parseAtUriFromWellKnownBody(body: string): string | null {
  const raw = body.trim();
  if (!raw.startsWith("at://")) return null;
  const token = raw.split(/\s+/)[0]!.trim();
  const p = parseAtUri(token);
  if (!p || !PUBLICATION_RECORD_COLLECTIONS.has(p.collection)) return null;
  return normalizeAtRepoParam(token);
}

async function tryWellKnownPublication(origin: string): Promise<string | null> {
  const u = new URL("/.well-known/site.standard.publication", origin);
  let res: Response;
  try {
    res = await fetchText(u.href);
  } catch {
    return null;
  }
  if (!res.ok) return null;
  try {
    return parseAtUriFromWellKnownBody(await res.text());
  } catch {
    return null;
  }
}

function collectAlternateFeedHrefs(html: string, baseUrl: URL): string[] {
  const out: string[] = [];
  const re = /<link\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const tag = m[0]!;
    const relM = /\brel\s*=\s*["']([^"']+)["']/i.exec(tag);
    const hrefM = /\bhref\s*=\s*["']([^"']+)["']/i.exec(tag);
    const typeM = /\btype\s*=\s*["']([^"']+)["']/i.exec(tag);
    if (!hrefM) continue;
    const relRaw = relM?.[1]?.toLowerCase() ?? "";
    const rels = relRaw.split(/\s+/).filter(Boolean);
    if (!rels.includes("alternate")) continue;
    const href = hrefM[1];
    const type = typeM?.[1]?.toLowerCase() ?? "";
    const rssishType =
      type.includes("rss") || type.includes("atom") || type.includes("xml");
    const rssishHref = /\.(rss|xml|atom)(\?|$)/i.test(href) || /feed/i.test(href);
    if (!rssishType && !rssishHref) continue;
    try {
      out.push(new URL(href, baseUrl).href);
    } catch {
      /* skip */
    }
  }
  return [...new Set(out)];
}

async function looksLikeRssFeed(normalizedFeedHref: string): Promise<{
  ok: boolean;
  title?: string;
  siteUrl?: string;
  feedIconUrl?: string;
}> {
  const valid = validateRssFeedFetchUrl(normalizedFeedHref);
  if (!valid.ok) return { ok: false };
  try {
    const res = await fetchText(valid.url.href);
    if (
      !res.ok &&
      res.status !== 406 &&
      res.status !== 403 &&
      res.status !== 415
    ) {
      return { ok: false };
    }
    const xml = (await res.text()) ?? "";
    const parsed = await parseRssFeedXml(xml);
    const items = await rssItemsSortedNewestFirst(xml);
    const feedTitle =
      typeof parsed.title === "string" ? parsed.title.trim() : undefined;
    if (items.length === 0 && !feedTitle) return { ok: false };
    const branding = feedBrandingFromParsed(parsed, normalizedFeedHref);
    return {
      ok: true,
      title: feedTitle || undefined,
      ...branding,
    };
  } catch {
    return { ok: false };
  }
}

async function discoverRssFromPageUrl(pageUrl: string): Promise<string | null> {
  const validPage = validateRssFeedFetchUrl(
    normalizeHttpUrlToHttps(pageUrl.trim())
  );
  if (!validPage.ok) return null;
  let res: Response;
  try {
    res = await fetchText(validPage.url.href);
  } catch {
    return null;
  }
  if (
    !res.ok &&
    res.status !== 406 &&
    res.status !== 403 &&
    res.status !== 415
  ) {
    return null;
  }
  let text: string;
  try {
    text = (await res.text()) ?? "";
  } catch {
    return null;
  }

  const ct = res.headers.get("content-type")?.toLowerCase() ?? "";
  if (/xml|rss|atom/.test(ct)) {
    const normalized = normalizeRssFeedUrlInput(validPage.url.href);
    const ok = await looksLikeRssFeed(normalized);
    return ok.ok ? normalized : null;
  }

  const normPage = normalizeRssFeedUrlInput(validPage.url.href);
  const pageProbe = await looksLikeRssFeed(normPage);
  if (pageProbe.ok) return normPage;

  const linked = collectAlternateFeedHrefs(text, validPage.url);
  for (const href of linked) {
    const norm = normalizeRssFeedUrlInput(href);
    const ok = await looksLikeRssFeed(norm);
    if (ok.ok) return norm;
  }

  const origin = validPage.url.origin;
  for (const path of [
    "/feed",
    "/feed.xml",
    "/rss",
    "/rss.xml",
    "/atom.xml",
    "/feeds/rss",
  ]) {
    const guess = new URL(path, origin).href;
    const norm = normalizeRssFeedUrlInput(guess);
    const ok = await looksLikeRssFeed(norm);
    if (ok.ok) return norm;
  }

  return null;
}

export type ResolveAddPublicationPayload =
  | {
      kind: "standard-site";
      publicationAtUri: string;
    }
  | {
      kind: "rss";
      feedUrl: string;
      title?: string;
      /** Canonical site origin derived from feed link or feed URL — stored on Skyreader subscription. */
      siteUrl?: string;
      /** Channel / feed-declared artwork (RSS image, Atom icon, iTunes image); stored as `customIconUrl`. */
      feedIconUrl?: string;
    };

export async function resolveAddPublicationInput(
  rawInput: string,
  options?: { signal?: AbortSignal }
): Promise<ResolveAddPublicationPayload | { error: string }> {
  const input = rawInput.trim();
  if (!input) return { error: "Enter a link or publication reference." };

  const signal = options?.signal;

  const atCandidate = normalizeAtRepoParam(input);
  if (atCandidate.startsWith("at://")) {
    const parsed = parseAtUri(atCandidate);
    if (parsed?.collection === "app.offprint.publication") {
      const record = await fetchPublicationRecordValue(atCandidate, undefined);
      const innerRaw = record?.publication;
      const inner =
        typeof innerRaw === "string" ? innerRaw.trim() : "";
      if (inner) {
        return {
          kind: "standard-site",
          publicationAtUri: normalizeAtRepoParam(inner),
        };
      }
      return {
        error:
          "Offprint publication record is missing its site.standard.publication reference.",
      };
    }
    if (parsed && PUBLICATION_RECORD_COLLECTIONS.has(parsed.collection)) {
      return {
        kind: "standard-site",
        publicationAtUri: atCandidate,
      };
    }
    return {
      error:
        "Unsupported AT-URI — use a publication record (site.standard.publication or com.standard.publication).",
    };
  }

  if (input.includes("://")) {
    const normalized = normalizeHttpUrlToHttps(input);
    const httpsCheck = validateRssFeedFetchUrl(normalized);
    if (!httpsCheck.ok) {
      return { error: httpsCheck.reason };
    }
    const pageUrl = httpsCheck.url.href;
    const publication = await tryWellKnownPublication(httpsCheck.url.origin);
    if (publication) {
      return { kind: "standard-site", publicationAtUri: publication };
    }

    const rssDirect = await looksLikeRssFeed(
      normalizeRssFeedUrlInput(pageUrl)
    );
    if (rssDirect.ok) {
      const norm = normalizeRssFeedUrlInput(pageUrl);
      return {
        kind: "rss",
        feedUrl: norm,
        title: rssDirect.title,
        siteUrl: rssDirect.siteUrl,
        feedIconUrl: rssDirect.feedIconUrl,
      };
    }

    const fromPage = await discoverRssFromPageUrl(pageUrl);
    if (fromPage) {
      const again = await looksLikeRssFeed(fromPage);
      return {
        kind: "rss",
        feedUrl: fromPage,
        title: again.title,
        siteUrl: again.siteUrl,
        feedIconUrl: again.feedIconUrl,
      };
    }

    return {
      error:
        "Could not find a standard.site publication marker for this domain or a reachable RSS/Atom feed. Try a publication AT-URI or a direct feed URL.",
    };
  }

  if (input.startsWith("did:")) {
    const pub = await probeFirstPublicationRecordUri(input, { signal });
    if (pub)
      return {
        kind: "standard-site",
        publicationAtUri: pub,
      };
    return {
      error:
        "No site.standard.publication (or com.standard.publication) records found for that DID.",
    };
  }

  const probed = await probeFirstPublicationRecordUri(input, { signal });
  if (probed) {
    return {
      kind: "standard-site",
      publicationAtUri: probed,
    };
  }

  const withScheme = normalizeHttpUrlToHttps(`https://${input}`);
  const check = validateRssFeedFetchUrl(withScheme);
  if (check.ok) {
    return resolveAddPublicationInput(withScheme, options);
  }

  return {
    error:
      "Could not interpret that as a Bluesky handle, DID, https URL, or publication AT-URI.",
  };
}
