/**
 * Client-safe RSS identifiers and feed URL normalization (no `rss-parser`).
 */

import { isBlockedEmbedProbeHostname } from "@/lib/embedFramePolicy";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

export const RSS_PUBLICATION_PREFIX = "rss:" as const;
export const RSS_ENTRY_PREFIX = "rssentry:" as const;

const UTF8_ENCODER = new TextEncoder();

function normalizeHostHint(h: string): string {
  return h.trim().toLowerCase().replace(/^\[|\]$/g, "");
}

/** UTF‑8 strings → Base64‑URL without Node `Buffer` (safe in the browser bundle). */
function utf8ToBase64Url(text: string): string {
  const bytes = UTF8_ENCODER.encode(text);
  let bin = "";
  for (let i = 0; i < bytes.length; i++)
    bin += String.fromCharCode(bytes[i]!);
  const b64 = btoa(bin);
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlToUtf8(b64url: string): string | null {
  try {
    let s = b64url.replace(/-/g, "+").replace(/_/g, "/");
    const pad = s.length % 4;
    if (pad !== 0) s += "=".repeat(4 - pad);
    const bin = atob(s);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)!;
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
}

/** Normalize user input to a canonical HTTPS feed URL string for storage + identity. */
export function normalizeRssFeedUrlInput(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "";
  return normalizeHttpUrlToHttps(trimmed);
}

export function validateRssFeedFetchUrl(raw: string):
  | { ok: true; url: URL }
  | { ok: false; reason: string } {
  let u: URL;
  try {
    u = new URL(raw.trim());
  } catch {
    return { ok: false, reason: "invalid url" };
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") {
    return { ok: false, reason: "only http(s) feeds are allowed" };
  }
  if (u.username || u.password) {
    return { ok: false, reason: "credentials in url are not allowed" };
  }
  const host = normalizeHostHint(u.hostname);
  if (!host || isBlockedEmbedProbeHostname(host)) {
    return { ok: false, reason: "host is not allowed" };
  }
  return { ok: true, url: u };
}

export function isRssPublicationId(key: string): boolean {
  return key.startsWith(RSS_PUBLICATION_PREFIX);
}

export function isRssEntryId(key: string): boolean {
  return key.startsWith(RSS_ENTRY_PREFIX);
}

export function rssPublicationIdFromNormalizedFeedUrl(
  normalizedFeedUrl: string
): string {
  return `${RSS_PUBLICATION_PREFIX}${utf8ToBase64Url(normalizedFeedUrl)}`;
}

export function normalizedFeedUrlFromRssPublicationId(pubId: string): string | null {
  if (!isRssPublicationId(pubId)) return null;
  const payload = pubId.slice(RSS_PUBLICATION_PREFIX.length);
  return base64UrlToUtf8(payload);
}

/** Stable dedupe key for an RSS / Atom row (parsed item shape). */
export function stableItemKeyFromRssItem(item: {
  guid?: unknown;
  link?: string;
  title?: string;
  isoDate?: string;
}): string {
  const gRaw = item.guid;
  let g =
    typeof gRaw === "string"
      ? gRaw.trim()
      : gRaw &&
          typeof gRaw === "object" &&
          gRaw !== null &&
          "_" in gRaw
        ? String((gRaw as { _?: unknown })._ ?? "").trim()
        : "";

  if (
    !g &&
    item.guid &&
    typeof item.guid === "object" &&
    item.guid !== null &&
    "$" in item.guid &&
    typeof (item.guid as { $?: unknown }).$ === "string"
  ) {
    g = String((item.guid as { $?: string }).$).trim();
  }

  const link = item.link?.trim();
  if (link) {
    try {
      return `link:${normalizeHttpUrlToHttps(link)}`;
    } catch {
      return `link:${link}`;
    }
  }
  if (g) {
    if (/^https?:\/\//i.test(g)) {
      try {
        return `guid:${normalizeHttpUrlToHttps(g)}`;
      } catch {
        return `guid:${g}`;
      }
    }
    return `guid:${g}`;
  }
  const title = item.title?.trim() ?? "";
  const d = item.isoDate?.trim() ?? "";
  return `fallback:${title}\n${d}`;
}

export function canonicalLinkForEntryListItem(item: {
  entryId: string;
  title: string;
  summary?: string | null;
  publishedAt: string;
}): string | null {
  const decoded = rssEntryIdDecode(item.entryId);
  if (decoded) {
    if (decoded.itemKey.startsWith("link:")) {
      const raw = decoded.itemKey.slice("link:".length);
      try {
        return normalizeHttpUrlToHttps(raw);
      } catch {
        return raw;
      }
    }
    if (decoded.itemKey.startsWith("guid:")) {
      const raw = decoded.itemKey.slice("guid:".length);
      if (/^https?:\/\//i.test(raw)) {
        try {
          return normalizeHttpUrlToHttps(raw);
        } catch {
          return raw;
        }
      }
    }
  }
  const summary = item.summary?.trim();
  if (summary && /^https?:\/\//i.test(summary)) {
    try {
      return normalizeHttpUrlToHttps(summary);
    } catch {
      return summary;
    }
  }
  return null;
}

export function dedupeEntryListItems<
  T extends {
    entryId: string;
    title: string;
    summary?: string | null;
    publishedAt: string;
  },
>(items: T[]): T[] {
  const seenEntryIds = new Set<string>();
  const seenCanonicalLinks = new Set<string>();
  const seenTitlePublished = new Set<string>();
  const deduped: T[] = [];

  for (const item of items) {
    if (seenEntryIds.has(item.entryId)) continue;
    seenEntryIds.add(item.entryId);

    const link = canonicalLinkForEntryListItem(item);
    if (link) {
      if (seenCanonicalLinks.has(link)) continue;
      seenCanonicalLinks.add(link);
    } else {
      const titleKey = `${item.title.trim().toLowerCase()}|${item.publishedAt}`;
      if (seenTitlePublished.has(titleKey)) continue;
      seenTitlePublished.add(titleKey);
    }

    deduped.push(item);
  }

  return deduped;
}

export function rssEntryIdFromParts(
  normalizedFeedUrl: string,
  stableItemKey: string
): string {
  const inner = JSON.stringify({
    f: normalizedFeedUrl,
    k: stableItemKey,
  });
  return `${RSS_ENTRY_PREFIX}${utf8ToBase64Url(inner)}`;
}

export function rssEntryIdDecode(
  entryId: string
): { feedUrl: string; itemKey: string } | null {
  if (!isRssEntryId(entryId)) return null;
  const inner = base64UrlToUtf8(entryId.slice(RSS_ENTRY_PREFIX.length));
  if (!inner) return null;
  try {
    const o = JSON.parse(inner) as { f?: string; k?: string };
    if (typeof o.f !== "string" || typeof o.k !== "string") return null;
    return { feedUrl: o.f, itemKey: o.k };
  } catch {
    return null;
  }
}
