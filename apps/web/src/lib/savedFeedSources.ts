import type { MergedLatrSave } from "@/lib/pdsClient";
import type { SidebarPublicationRow } from "@/lib/publicationProjectionClient";
import {
  matchSavedLinkPublicationFromSidebar,
  resolveSavedLinkPublicationWithSidebar,
  siteHostKey,
} from "@/lib/savedLinkPublication";

export type SavedFeedSource = {
  key: string;
  name: string;
  faviconUrl?: string;
  count: number;
};

export function savedFeedSourceKey(
  row: MergedLatrSave,
  sidebarRows: SidebarPublicationRow[],
): string | null {
  const matched = matchSavedLinkPublicationFromSidebar(row, sidebarRows);
  if (matched) return `publication:${matched.publicationId}`;
  const resolved = resolveSavedLinkPublicationWithSidebar(row, sidebarRows);
  if (!resolved) return null;
  const siteKey =
    (resolved.homepageUrl && siteHostKey(resolved.homepageUrl)) ||
    siteHostKey(resolved.name) ||
    resolved.name.trim().toLowerCase();
  return siteKey ? `site:${siteKey}` : null;
}

export function savedFeedSources(
  rows: MergedLatrSave[],
  sidebarRows: SidebarPublicationRow[],
): SavedFeedSource[] {
  const byKey = new Map<string, SavedFeedSource>();
  for (const row of rows) {
    const key = savedFeedSourceKey(row, sidebarRows);
    if (!key) continue;
    const resolved = resolveSavedLinkPublicationWithSidebar(row, sidebarRows);
    if (!resolved) continue;
    const existing = byKey.get(key);
    if (existing) {
      existing.count += 1;
    } else {
      byKey.set(key, {
        key,
        name: resolved.name,
        faviconUrl: resolved.faviconUrl,
        count: 1,
      });
    }
  }
  return Array.from(byKey.values()).sort((a, b) =>
    a.name.localeCompare(b.name),
  );
}
