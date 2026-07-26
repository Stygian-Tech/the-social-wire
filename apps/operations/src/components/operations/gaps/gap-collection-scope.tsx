import { gapCollectionScopeLabel } from "@/lib/backfill-collections"

export function GapCollectionScope({ collections }: { collections: readonly string[] }) {
  const unknown = collections.length === 0
  return (
    <span
      className={unknown ? "text-warning" : undefined}
      title={unknown ? "The detector could not attribute this gap to specific collections." : collections.join(", ")}
    >
      {gapCollectionScopeLabel(collections)}
    </span>
  )
}
