import { boundedNonNegativeInteger } from "@/lib/observability-values"
import type { ViewerCounts } from "@/lib/operations-types"

const DAY_MS = 86_400_000

export type UserCountTrend = {
  timestamp: number
  known: number | null
  mau: number | null
  wau: number | null
}

export function userCountTrends(history: ViewerCounts[], referenceTime: string): UserCountTrend[] {
  const reference = Date.parse(referenceTime)
  if (!Number.isFinite(reference)) return []
  const today = Math.floor(reference / DAY_MS) * DAY_MS
  const firstDay = today - 89 * DAY_MS
  const daily = new Map<number, ViewerCounts>()
  for (const observation of history) {
    const observedAt = Date.parse(observation.observedAt)
    const day = Math.floor(observedAt / DAY_MS) * DAY_MS
    if (!Number.isFinite(observedAt) || observedAt > reference || day < firstDay) continue
    const existing = daily.get(day)
    if (!existing || observedAt > Date.parse(existing.observedAt)) daily.set(day, observation)
  }
  return Array.from({ length: 90 }, (_, index) => {
    const timestamp = firstDay + index * DAY_MS
    const observation = daily.get(timestamp)
    return {
      timestamp,
      known: boundedNonNegativeInteger(observation?.knownViewers),
      mau: boundedNonNegativeInteger(observation?.activeViewers30d),
      wau: boundedNonNegativeInteger(observation?.activeViewers7d),
    }
  })
}

export function formatUserCountDate(timestamp: number): string {
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", timeZone: "UTC" }).format(timestamp)
}
