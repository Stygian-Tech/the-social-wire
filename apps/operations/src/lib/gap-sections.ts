import type { Backfill, Gap } from "@/lib/operations-types"

export function partitionGapsByBackfillCompletion(gaps: Gap[], backfills: Backfill[]) {
  const completedBackfillIds = new Set<string>()
  const completedGapIds = new Set<string>()

  for (const backfill of backfills) {
    if (backfill.status !== "completed") continue

    completedBackfillIds.add(backfill.id)
    if (backfill.gapId) completedGapIds.add(backfill.gapId)
  }

  const activeGaps: Gap[] = []
  const backfilledGaps: Gap[] = []
  const inactiveGaps: Gap[] = []

  for (const gap of gaps) {
    const hasCompletedBackfill =
      completedGapIds.has(gap.id) ||
      (gap.backfillJobId !== undefined && completedBackfillIds.has(gap.backfillJobId)) ||
      (gap.status === "resolved" && gap.backfillJobId !== undefined)

    if (hasCompletedBackfill) backfilledGaps.push(gap)
    else if (gap.status === "resolved" || gap.status === "ignored") inactiveGaps.push(gap)
    else activeGaps.push(gap)
  }

  return { activeGaps, backfilledGaps, inactiveGaps }
}
