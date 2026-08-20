import { describe, expect, it } from "bun:test"
import { redisOperationsSummary, redisOperationsTrends } from "@/lib/redis-metrics"
import type { MetricRollup } from "@/lib/operations-types"

function rollup(
  metricName: string,
  valueSum: number,
  dimensions: Record<string, string> = {},
  sampleCount = 1,
  valueMax?: number,
): MetricRollup {
  return {
    environment: "dev",
    bucketStart: "2026-08-11T12:00:00.000Z",
    metricName,
    dimensions,
    sampleCount,
    valueSum,
    valueMax,
  }
}

describe("redisOperationsSummary", () => {
  it("aggregates bounded Redis evidence without inventing percentiles", () => {
    const summary = redisOperationsSummary([
      rollup("socialwire.appview.cache.lookups_total", 12, { outcome: "fresh_hit" }),
      rollup("socialwire.appview.cache.lookups_total", 3, { outcome: "stale_hit" }),
      rollup("socialwire.appview.cache.lookups_total", 2, { outcome: "miss" }),
      rollup("socialwire.redis.operation.duration_seconds", 0.05, {}, 2, 0.04),
      rollup("socialwire.appview.cache.locks_total", 4, { outcome: "acquired" }),
      rollup("socialwire.appview.cache.locks_total", 1, { outcome: "contended" }),
      rollup("socialwire.redis.errors_total", 2),
      rollup("socialwire.redis.circuit_state", 1, { state: "open" }),
      rollup("socialwire.appview.unread.recomputes_total", 5, { reason: "missing" }),
      rollup("socialwire.redis.expired_keys", 40),
      rollup("socialwire.redis.evicted_keys", 2),
      rollup("socialwire.redis.memory_used_bytes", 2_000_000),
    ])

    expect(summary.lookups).toEqual({ fresh: 12, stale: 3, miss: 2, malformed: 0, fallback: 0 })
    expect(summary.averageOperationMilliseconds).toBe(25)
    expect(summary.maximumOperationMilliseconds).toBe(40)
    expect(summary.locksAcquired).toBe(4)
    expect(summary.lockContention).toBe(1)
    expect(summary.errors).toBe(2)
    expect(summary.circuitOpenSamples).toBe(1)
    expect(summary.unreadRecomputes).toEqual({ missing: 5 })
    expect(summary.memoryUsedBytes).toBe(2_000_000)
  })

  it("returns an explicit empty state for absent evidence", () => {
    const summary = redisOperationsSummary([])
    expect(summary.operationSamples).toBe(0)
    expect(summary.averageOperationMilliseconds).toBeNull()
    expect(summary.maximumOperationMilliseconds).toBeNull()
    expect(summary.memoryUsedBytes).toBeNull()
  })
})

describe("redisOperationsTrends", () => {
  it("keeps missing minutes explicit and groups related Redis evidence", () => {
    const duration = rollup("socialwire.redis.operation.duration_seconds", 0.05, {}, 2, 0.04)
    const lookups = rollup("socialwire.appview.cache.lookups_total", 12, { outcome: "fresh_hit" })
    lookups.bucketStart = "2026-08-11T12:02:00.000Z"

    expect(redisOperationsTrends([duration, lookups])).toEqual([
      expect.objectContaining({
        timestamp: Date.parse("2026-08-11T12:00:00.000Z"),
        averageOperationMilliseconds: 25,
        maximumOperationMilliseconds: 40,
        freshLookups: null,
      }),
      expect.objectContaining({
        timestamp: Date.parse("2026-08-11T12:01:00.000Z"),
        averageOperationMilliseconds: null,
        freshLookups: null,
      }),
      expect.objectContaining({
        timestamp: Date.parse("2026-08-11T12:02:00.000Z"),
        averageOperationMilliseconds: null,
        freshLookups: 12,
      }),
    ])
  })
})
