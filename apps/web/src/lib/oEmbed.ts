/** oEmbed discovery and response helpers (safe for client + server). */

export type OEmbedType = "photo" | "video" | "link" | "rich";

export type OEmbedResponse = {
  type: OEmbedType;
  version?: string;
  title?: string;
  author_name?: string;
  provider_name?: string;
  provider_url?: string;
  cache_age?: number;
  thumbnail_url?: string;
  thumbnail_width?: number;
  thumbnail_height?: number;
  url?: string;
  width?: number;
  height?: number;
  html?: string;
};

export type OEmbedLookupResult =
  | { ok: true; oembed: OEmbedResponse; canonicalUrl: string; pageAtUri?: string }
  | {
      ok: false;
      reason: "invalid" | "not_found" | "unusable" | "fetch_failed";
      pageAtUri?: string;
    };

const OEMBED_LINK_RE =
  /<link\b[^>]*\btype=["']application\/json\+oembed["'][^>]*>/gi;
const HEAD_RE = /<head\b[^>]*>([\s\S]*?)<\/head>/i;
const HEAD_AT_URI_TAG_RE = /<(?:meta|link)\b[^>]*>/gi;
const STANDARD_SITE_ARTICLE_COLLECTIONS = new Set([
  "site.standard.document",
  "site.standard.entry",
]);

function readLinkAttr(tag: string, name: string): string | null {
  const re = new RegExp(`\\b${name}\\s*=\\s*(["'])([^"']*)\\1`, "i");
  const m = tag.match(re);
  return m?.[2]?.trim() ?? null;
}

/** Extract oEmbed endpoint URL from publisher HTML `<link rel="alternate">` tags. */
export function extractOEmbedEndpointFromHtml(html: string): string | null {
  OEMBED_LINK_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = OEMBED_LINK_RE.exec(html)) !== null) {
    const tag = m[0];
    const href = readLinkAttr(tag, "href");
    if (!href) continue;
    try {
      const u = new URL(href);
      if (u.protocol === "https:") return u.href;
    } catch {
      continue;
    }
  }
  return null;
}

function headHtml(html: string): string {
  const m = html.match(HEAD_RE);
  return m?.[1] ?? html.slice(0, 64_000);
}

function standardSiteArticleAtUri(value: string | null): string | null {
  if (!value) return null;
  const decoded = value.trim();
  const m = decoded.match(
    /^at:\/\/([^/\s"'<>]+)\/([^/\s"'<>]+)\/([^/\s"'<>?#]+)$/i
  );
  if (!m) return null;
  const collection = m[2];
  if (!STANDARD_SITE_ARTICLE_COLLECTIONS.has(collection)) return null;
  return `at://${m[1]}/${collection}/${m[3]}`;
}

function tagNamesStandardSiteAtUri(tag: string): boolean {
  for (const attr of ["name", "property", "itemprop", "rel"]) {
    const value = readLinkAttr(tag, attr)?.toLowerCase();
    if (!value) continue;
    if (
      value === "at-uri" ||
      value === "at:uri" ||
      value === "atproto:uri" ||
      value === "atproto-uri" ||
      value === "standard-site-at-uri" ||
      value === "standard.site.at-uri"
    ) {
      return true;
    }
  }
  return false;
}

/** Extracts the standard.site article AT URI advertised by publisher `<head>` metadata. */
export function extractStandardSiteArticleAtUriFromHtml(
  html: string
): string | null {
  const head = headHtml(html);
  HEAD_AT_URI_TAG_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = HEAD_AT_URI_TAG_RE.exec(head)) !== null) {
    const tag = m[0];
    if (!tagNamesStandardSiteAtUri(tag)) continue;
    const atUri =
      standardSiteArticleAtUri(readLinkAttr(tag, "content")) ??
      standardSiteArticleAtUri(readLinkAttr(tag, "href"));
    if (atUri) return atUri;
  }
  return null;
}

export function wordPressOEmbedEndpoint(origin: string): string {
  return new URL("/wp-json/oembed/1.0/embed", origin).href;
}

export function parseOEmbedJson(raw: unknown): OEmbedResponse | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const type = obj.type;
  if (type !== "photo" && type !== "video" && type !== "link" && type !== "rich") {
    return null;
  }
  const out: OEmbedResponse = { type };
  for (const key of [
    "version",
    "title",
    "author_name",
    "provider_name",
    "provider_url",
    "thumbnail_url",
    "url",
    "html",
  ] as const) {
    const v = obj[key];
    if (typeof v === "string" && v.trim()) {
      out[key] = v.trim();
    }
  }
  for (const key of [
    "cache_age",
    "thumbnail_width",
    "thumbnail_height",
    "width",
    "height",
  ] as const) {
    const v = obj[key];
    if (typeof v === "number" && Number.isFinite(v)) {
      out[key] = v;
    }
  }
  return out;
}

function isHttpsUrl(value: string | undefined): boolean {
  if (!value) return false;
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}

/** Whether an oEmbed payload is worth rendering before falling back to a raw iframe. */
export function isUsableOEmbedResponse(oembed: OEmbedResponse): boolean {
  switch (oembed.type) {
    case "photo":
      return isHttpsUrl(oembed.url);
    case "video":
      return Boolean(oembed.html?.trim()) || isHttpsUrl(oembed.url);
    case "rich": {
      const html = oembed.html?.trim();
      if (!html) return false;
      if (/<iframe\b/i.test(html)) return true;
      const text = html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
      return text.length >= 40;
    }
    case "link":
    default:
      return false;
  }
}

export function oEmbedRequestUrl(endpoint: string, pageUrl: string): string {
  const u = new URL(endpoint);
  u.searchParams.set("url", pageUrl);
  u.searchParams.set("format", "json");
  return u.href;
}

const VIDEO_EMBED_HOST_SUFFIXES = [
  "youtube.com",
  "youtube-nocookie.com",
  "vimeo.com",
  "tiktok.com",
  "twitch.tv",
  "dailymotion.com",
  "loom.com",
];

export function extractIframeSrcFromEmbedHtml(html: string): string | null {
  const m = html.match(/<iframe\b[^>]*\bsrc=(["'])([^"']+)\1/i);
  return m?.[2]?.trim() ?? null;
}

export function isVideoEmbedIframeSrc(src: string): boolean {
  try {
    const host = new URL(src).hostname.replace(/^www\./i, "").toLowerCase();
    return VIDEO_EMBED_HOST_SUFFIXES.some(
      (suffix) => host === suffix || host.endsWith(`.${suffix}`)
    );
  } catch {
    return false;
  }
}

/** Layout hint for provider HTML — article iframes should fill the reader pane. */
export function oEmbedHtmlLayout(html: string): "video" | "article" {
  const src = extractIframeSrcFromEmbedHtml(html);
  if (src && isVideoEmbedIframeSrc(src)) {
    return "video";
  }
  return "article";
}
