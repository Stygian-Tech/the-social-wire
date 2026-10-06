/** React Query key for the canonical sidebar projection blob (per viewer DID). */
export const PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY = (did: string) =>
  // Old persisted projections include podcast subscriptions in the article sidebar.
  ["publicationSidebarProjection", did, "podcast-category-v1"] as const;
