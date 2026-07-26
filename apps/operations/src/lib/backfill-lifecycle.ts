import type { Backfill } from "@/lib/operations-types"

const activeStatuses = new Set<Backfill["status"]>(["queued", "running", "paused"])
const attentionStatuses = new Set<Backfill["status"]>(["failed", "cancelled"])

export type BackfillLifecycle = {
  active: Backfill[]
  needsAttention: Backfill[]
  history: Backfill[]
}

export function partitionBackfills(backfills: Backfill[]): BackfillLifecycle {
  const result: BackfillLifecycle = { active: [], needsAttention: [], history: [] }

  for (const backfill of backfills) {
    if (activeStatuses.has(backfill.status)) result.active.push(backfill)
    else if (attentionStatuses.has(backfill.status)) result.needsAttention.push(backfill)
    else if (backfill.status === "completed") result.history.push(backfill)
  }

  return result
}

export function allowedBackfillActions(status: Backfill["status"]) {
  if (status === "queued") return ["cancel"] as const
  if (status === "running") return ["pause", "cancel"] as const
  if (status === "paused") return ["resume", "cancel"] as const
  return [] as const
}

export function isBackfillTerminal(status: Backfill["status"]) {
  return status === "completed" || status === "failed" || status === "cancelled"
}
