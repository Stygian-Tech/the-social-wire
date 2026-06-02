import type { EntryDetail } from "@/lib/atprotoClient";
import { normalizeAtRepoParam, parseAtUri } from "@/lib/atprotoClient";
import { isLatrExternalSubjectUri } from "@/lib/latrCollections";
import type { MergedLatrSave } from "@/lib/pdsClient";
import { resolveSavedLinkEmbedUrl } from "@/lib/savedLinkEmbedUrl";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

export { isLatrExternalSubjectUri };

const ORIGINAL_ENTRY_COLLECTIONS = new Set([
  "site.standard.document",
  "com.standard.document",
  "site.standard.entry",
  "com.standard.entry",
]);

export function isOriginalEntryContentUri(uri: string): boolean {
  const parsed = parseAtUri(uri);
  return parsed ? ORIGINAL_ENTRY_COLLECTIONS.has(parsed.collection) : false;
}

/** AT-URI of the original publication entry — never the L@tr saved item / external wrapper. */
export function originalEntryIdFromLatrSave(row: MergedLatrSave): string | null {
  if (row.kind !== "native") return null;
  const subjectUri = normalizeAtRepoParam(row.subjectUri);
  if (!isOriginalEntryContentUri(subjectUri)) return null;
  return subjectUri;
}

/**
 * Quote / link-card fallback when the save has no resolvable native entry record
 * (HTTPS external saves). Social like/repost/reply still require `bskyPostRef` on the
 * fetched native entry when available.
 */
export function latrSaveFallbackEntryDetail(row: MergedLatrSave): EntryDetail | null {
  const url =
    resolveSavedLinkEmbedUrl(row) ??
    row.linkedWebUrl?.trim() ??
    (row.kind === "external" ? row.url.trim() : row.url?.trim());
  if (!url) return null;

  const normalizedUrl = normalizeHttpUrlToHttps(url);
  const entryId =
    originalEntryIdFromLatrSave(row) ??
    (row.kind === "native" && !isLatrExternalSubjectUri(row.subjectUri)
      ? normalizeAtRepoParam(row.subjectUri)
      : "saved-link:external");

  return {
    entryId,
    title: row.title?.trim() || normalizedUrl,
    publishedAt: row.publishedAt?.trim() || row.savedAt,
    contentHtml: "",
    originalUrl: normalizedUrl,
    embedUrl: normalizedUrl,
  };
}
