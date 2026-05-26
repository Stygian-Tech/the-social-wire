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
  | { ok: true; oembed: OEmbedResponse; canonicalUrl: string }
  | { ok: false; reason: "invalid" | "not_found" | "unusable" | "fetch_failed" };

const OEMBED_LINK_RE =
  /<link\b[^>]*\btype=["']application\/json\+oembed["'][^>]*>/gi;

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
