/** React Query key for the canonical sidebar projection blob (per viewer DID). */
export const PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY = (did: string) =>
  ["publicationSidebarProjection", did] as const;
