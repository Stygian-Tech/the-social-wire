export const BACKFILL_COLLECTION_OPTIONS = [
  "site.standard.document",
  "site.standard.entry",
  "app.skyreader.feed.subscription",
] as const

export type RecoveryCollectionMode = "tap_verified_resync" | "jetstream_replay" | "pds_reconciliation"

const VERIFIED_REPOSITORY_COLLECTIONS = ["site.standard.document", "site.standard.entry"] as const

export function recoveryCollectionOptions(mode: RecoveryCollectionMode): readonly string[] {
  return mode === "jetstream_replay" ? BACKFILL_COLLECTION_OPTIONS : VERIFIED_REPOSITORY_COLLECTIONS
}

export const LEGACY_DIAGNOSTIC_COLLECTIONS = new Set([
  "site.standard.graph.subscription",
  "com.standard.document",
  "com.standard.entry",
])

export function initialBackfillCollections(
  collections: readonly string[],
  mode: RecoveryCollectionMode = "tap_verified_resync",
) {
  const supported = recoveryCollectionOptions(mode)
  return collections.filter((collection) => supported.includes(collection))
}

export function gapCollectionScopeLabel(collections: readonly string[]) {
  return collections.length > 0 ? collections.length.toLocaleString() : "Unknown"
}
