export type ReadLaterSaveTarget = {
  subject: string;
  title?: string;
  excerpt?: string;
};

/**
 * Community bookmarks store the encountered HTTPS article URL whenever one is
 * available. AT URIs are retained only when no web URL exists.
 */
export function resolveReadLaterSaveTarget(params: {
  entryId: string;
  url?: string;
  title?: string;
  excerpt?: string;
}): ReadLaterSaveTarget {
  return {
    subject: params.url?.trim() || params.entryId.trim(),
    title: params.title,
    excerpt: params.excerpt,
  };
}
