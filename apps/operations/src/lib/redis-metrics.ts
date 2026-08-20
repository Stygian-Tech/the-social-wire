import type { MetricRollup } from "@/lib/operations-types"

const LOOKUPS = "socialwire.appview.cache.lookups_total"
const DURATION = "socialwire.redis.operation.duration_seconds"
const LOCKS = "socialwire.appview.cache.locks_total"
const ERRORS = "socialwire.redis.errors_total"
const CIRCUIT = "socialwire.redis.circuit_state"
const UNREAD_RECOMPUTES = "socialwire.appview.unread.recomputes_total"
const EXPIRED_KEYS = "socialwire.redis.expired_keys"
const EVICTED_KEYS = "socialwire.redis.evicted_keys"
const MEMORY_BYTES = "socialwire.redis.memory_used_bytes"

export type RedisOperationsSummary = {
  lookups: Record<"fresh" | "stale" | "miss" | "malformed" | "fallback", number>
  operationSamples: number
  averageOperationMilliseconds: number | null
  maximumOperationMilliseconds: number | null
  locksAcquired: number
  lockContention: number
  errors: number
  circuitOpenSamples: number
  unreadRecomputes: Record<string, number>
  expiredKeys: number | null
  evictedKeys: number | null
  memoryUsedBytes: number | null
}

export type RedisTrendPoint = {
  timestamp: number
  freshLookups: number | null
  staleLookups: number | null
  missedLookups: number | null
  malformedLookups: number | null
  fallbackLookups: number | null
  averageOperationMilliseconds: number | null
  maximumOperationMilliseconds: number | null
  locksAcquired: number | null
  lockContention: number | null
  errors: number | null
  circuitOpenSamples: number | null
  unreadRecomputes: number | null
  expiredKeys: number | null
  evictedKeys: number | null
  memoryUsedBytes: number | null
}

function finiteNonnegative(value: number | undefined) {
  return value !== undefined && Number.isFinite(value) && value >= 0 ? value : null
}

function gaugeMaximum(rollup: MetricRollup, sum: number) {
  return finiteNonnegative(rollup.valueMax)
    ?? (rollup.sampleCount > 0 ? sum / rollup.sampleCount : null)
}

export function redisOperationsSummary(rollups: MetricRollup[]): RedisOperationsSummary {
  const summary: RedisOperationsSummary = {
    lookups: { fresh: 0, stale: 0, miss: 0, malformed: 0, fallback: 0 },
    operationSamples: 0,
    averageOperationMilliseconds: null,
    maximumOperationMilliseconds: null,
    locksAcquired: 0,
    lockContention: 0,
    errors: 0,
    circuitOpenSamples: 0,
    unreadRecomputes: {},
    expiredKeys: null,
    evictedKeys: null,
    memoryUsedBytes: null,
  }
  let durationSum = 0

  for (const rollup of rollups) {
    if (!Number.isSafeInteger(rollup.sampleCount) || rollup.sampleCount < 0) continue
    const sum = finiteNonnegative(rollup.valueSum)
    if (sum === null) continue

    if (rollup.metricName === LOOKUPS) {
      const outcome = rollup.dimensions.outcome?.replace("_hit", "")
      if (outcome && outcome in summary.lookups)
        summary.lookups[outcome as keyof typeof summary.lookups] += sum
      continue
    }
    if (rollup.metricName === DURATION) {
      summary.operationSamples += rollup.sampleCount
      durationSum += sum
      const maximum = finiteNonnegative(rollup.valueMax)
      if (maximum !== null)
        summary.maximumOperationMilliseconds = Math.max(
          summary.maximumOperationMilliseconds ?? 0,
          maximum * 1_000,
        )
      continue
    }
    if (rollup.metricName === LOCKS) {
      if (rollup.dimensions.outcome === "acquired") summary.locksAcquired += sum
      if (rollup.dimensions.outcome === "contended") summary.lockContention += sum
      continue
    }
    if (rollup.metricName === ERRORS) {
      summary.errors += sum
      continue
    }
    if (rollup.metricName === CIRCUIT) {
      summary.circuitOpenSamples += sum
      continue
    }
    if (rollup.metricName === UNREAD_RECOMPUTES) {
      const reason = rollup.dimensions.reason ?? "unknown"
      summary.unreadRecomputes[reason] = (summary.unreadRecomputes[reason] ?? 0) + sum
      continue
    }
    if (rollup.metricName === EXPIRED_KEYS) {
      const maximum = gaugeMaximum(rollup, sum)
      if (maximum !== null) summary.expiredKeys = Math.max(summary.expiredKeys ?? 0, maximum)
    }
    if (rollup.metricName === EVICTED_KEYS) {
      const maximum = gaugeMaximum(rollup, sum)
      if (maximum !== null) summary.evictedKeys = Math.max(summary.evictedKeys ?? 0, maximum)
    }
    if (rollup.metricName === MEMORY_BYTES) {
      const maximum = gaugeMaximum(rollup, sum)
      if (maximum !== null) summary.memoryUsedBytes = Math.max(summary.memoryUsedBytes ?? 0, maximum)
    }
  }

  summary.averageOperationMilliseconds = summary.operationSamples > 0
    ? (durationSum / summary.operationSamples) * 1_000
    : null
  return summary
}

export function redisOperationsTrends(rollups: MetricRollup[]): RedisTrendPoint[] {
  const relevant = rollups.filter((rollup) =>
    [LOOKUPS, DURATION, LOCKS, ERRORS, CIRCUIT, UNREAD_RECOMPUTES, EXPIRED_KEYS, EVICTED_KEYS, MEMORY_BYTES]
      .includes(rollup.metricName),
  )
  const timestamps = relevant
    .map(({ bucketStart }) => new Date(bucketStart).getTime())
    .filter(Number.isFinite)
  if (timestamps.length === 0) return []
  const start = Math.min(...timestamps)
  const end = Math.max(...timestamps)
  const rollupsByTimestamp = new Map<number, MetricRollup[]>()
  for (const rollup of relevant) {
    const timestamp = new Date(rollup.bucketStart).getTime()
    const bucket = rollupsByTimestamp.get(timestamp) ?? []
    bucket.push(rollup)
    rollupsByTimestamp.set(timestamp, bucket)
  }

  return Array.from({ length: Math.floor((end - start) / 60_000) + 1 }, (_, index) => {
    const timestamp = start + index * 60_000
    const bucket = rollupsByTimestamp.get(timestamp) ?? []
    const summary = redisOperationsSummary(bucket)
    const has = (metricName: string) => bucket.some((rollup) => rollup.metricName === metricName)
    return {
      timestamp,
      freshLookups: has(LOOKUPS) ? summary.lookups.fresh : null,
      staleLookups: has(LOOKUPS) ? summary.lookups.stale : null,
      missedLookups: has(LOOKUPS) ? summary.lookups.miss : null,
      malformedLookups: has(LOOKUPS) ? summary.lookups.malformed : null,
      fallbackLookups: has(LOOKUPS) ? summary.lookups.fallback : null,
      averageOperationMilliseconds: has(DURATION) ? summary.averageOperationMilliseconds : null,
      maximumOperationMilliseconds: has(DURATION) ? summary.maximumOperationMilliseconds : null,
      locksAcquired: has(LOCKS) ? summary.locksAcquired : null,
      lockContention: has(LOCKS) ? summary.lockContention : null,
      errors: has(ERRORS) ? summary.errors : null,
      circuitOpenSamples: has(CIRCUIT) ? summary.circuitOpenSamples : null,
      unreadRecomputes: has(UNREAD_RECOMPUTES)
        ? Object.values(summary.unreadRecomputes).reduce((total, value) => total + value, 0)
        : null,
      expiredKeys: has(EXPIRED_KEYS) ? summary.expiredKeys : null,
      evictedKeys: has(EVICTED_KEYS) ? summary.evictedKeys : null,
      memoryUsedBytes: has(MEMORY_BYTES) ? summary.memoryUsedBytes : null,
    }
  })
}
