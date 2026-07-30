import {
  normalizeAtRepoParam,
  parseAtUri,
} from "@/lib/atprotoClient";

export const STANDARD_SITE_RECOMMEND_COLLECTION =
  "site.standard.graph.recommend";

export interface StandardSiteRecommendRecord {
  $type: typeof STANDARD_SITE_RECOMMEND_COLLECTION;
  document: string;
  createdAt: string;
}

export function standardSiteRecommendDocumentUri(
  entryId: string | null | undefined
): string | null {
  const normalized = entryId ? normalizeAtRepoParam(entryId) : "";
  const parsed = normalized ? parseAtUri(normalized) : null;
  if (!parsed || parsed.collection !== "site.standard.document") return null;
  return normalized;
}
