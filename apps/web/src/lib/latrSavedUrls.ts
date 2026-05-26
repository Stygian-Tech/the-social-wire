/**
 * URL normalization + deterministic repo keys aligned with upstream L@tr (latr-kit / latr-packages).
 */

import {
  bytesToBase32Upper,
  latrExternalRkeyFromNormalizedUrl,
  latrFingerprintFromNormalizedUrl,
  latrFingerprintHex,
  latrItemRkeyFromSubjectUri,
  sha256Utf8,
} from "@stygian/latr-record-keys";

import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

export {
  bytesToBase32Upper,
  latrExternalRkeyFromNormalizedUrl,
  latrFingerprintFromNormalizedUrl,
  latrFingerprintHex,
  latrItemRkeyFromSubjectUri,
  sha256Utf8,
};

const TRACKING_PARAMS = new Set([
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_term",
  "utm_content",
  "fbclid",
  "gclid",
  "ref",
]);

function stripTracking(searchParams: URLSearchParams): void {
  const toDelete: string[] = [];
  for (const key of searchParams.keys()) {
    const lower = key.toLowerCase();
    if (lower.startsWith("utm_") || TRACKING_PARAMS.has(lower)) {
      toDelete.push(key);
    }
  }
  for (const k of toDelete) {
    searchParams.delete(k);
  }
}

/**
 * Returns a canonical normalized URL string or `null` if input is not http(s).
 */
export function normalizeLatrHttpsUrl(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const promoted = normalizeHttpUrlToHttps(trimmed);
  if (!promoted.trim()) return null;

  let url: URL;
  try {
    url = new URL(promoted);
  } catch {
    return null;
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return null;
  }

  url.protocol = url.protocol.toLowerCase();
  url.hostname = url.hostname.toLowerCase();
  url.hash = "";

  stripTracking(url.searchParams);
  url.searchParams.sort();

  if (url.pathname !== "/" && url.pathname.endsWith("/")) {
    url.pathname = url.pathname.replace(/\/+$/, "");
  }

  return url.toString();
}
