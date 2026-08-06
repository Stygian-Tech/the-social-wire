import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getEntry, parseAtUri } from "@/lib/atprotoClient";

const STANDARD_SITE_ENTRY_COLLECTIONS = new Set([
  "site.standard.document",
  "site.standard.entry",
  "com.standard.document",
  "com.standard.entry",
]);

export function isStandardSiteEntryId(entryId: string): boolean {
  const parsed = parseAtUri(entryId);
  return parsed ? STANDARD_SITE_ENTRY_COLLECTIONS.has(parsed.collection) : false;
}

/**
 * Recovers the hosted article URL for a standard.site entry directly from the author's PDS.
 *
 * The AppView index can be missing `originalUrl` — the document references its publication by
 * AT-URI and the publication record has not been resolved yet — which would otherwise leave the
 * entry with no destination to open. Resolution failures return `undefined` rather than throwing
 * so callers can fall back to user-visible feedback.
 */
export async function resolveEntryOpenUrlFromPds(
  entryId: string,
  oauthSession?: OAuthSession,
): Promise<string | undefined> {
  if (!isStandardSiteEntryId(entryId)) return undefined;
  try {
    const entry = await getEntry(entryId, oauthSession);
    return entry?.originalUrl ?? entry?.embedUrl ?? undefined;
  } catch {
    return undefined;
  }
}
