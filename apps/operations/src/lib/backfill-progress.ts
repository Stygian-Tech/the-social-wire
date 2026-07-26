import type { Backfill } from "@/lib/operations-types"

export function backfillRateLimitLabel(job: Pick<Backfill, "rateLimit" | "sourceMode">) {
  const unit = job.sourceMode === "pds_reconciliation" ? "PDS requests/s" : "source events/s"
  return `≤ ${job.rateLimit.toLocaleString()} ${unit}`
}

export type BackfillProgressEvidence = {
  observedCount: number | null
  estimatedCount: number | null
  percentOfEstimate: number | null
  boundedPercent: number
  valid: boolean
}

function observedCount(value: number) {
  return Number.isSafeInteger(value) && value >= 0 ? value : null
}

export function backfillProgressEvidence(job: Backfill): BackfillProgressEvidence {
  const processed = observedCount(job.processedCount)
  const estimate = observedCount(job.estimatedCount)
  const valid = processed !== null && estimate !== null

  if (!valid || estimate === 0) {
    return {
      observedCount: processed,
      estimatedCount: estimate,
      percentOfEstimate: null,
      boundedPercent: 0,
      valid,
    }
  }

  const percentOfEstimate = (processed / estimate) * 100
  return {
    observedCount: processed,
    estimatedCount: estimate,
    percentOfEstimate,
    boundedPercent: Math.min(100, Math.max(0, percentOfEstimate)),
    valid,
  }
}

export function backfillProgressPercent(job: Backfill): number {
  return backfillProgressEvidence(job).boundedPercent
}
