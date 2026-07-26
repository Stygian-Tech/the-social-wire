import { describe, expect, it } from "bun:test"
import {
  collectionMetricRows,
  currentMetricValue,
  latestMetricValue,
  MONITORED_COLLECTIONS,
  metricWindowReference,
  metricSampleCount,
} from "@/lib/collection-metrics"
import type { MetricRollup } from "@/lib/operations-types"

function rollup(overrides: Partial<MetricRollup> = {}): MetricRollup {
  return {
    environment: "dev",
    bucketStart: "2026-07-20T20:00:00.000Z",
    metricName: "socialwire.ingestion.events_total",
    dimensions: { collection: "site.standard.document", operation: "create", ingestion_mode: "live" },
    sampleCount: 120,
    valueSum: 120,
    valueMin: 1,
    valueMax: 1,
    ...overrides,
  }
}

describe("collectionMetricRows", () => {
  it("derives per-second trends from retained one-minute counter buckets", () => {
    const rows = collectionMetricRows([
      rollup(),
      rollup({ bucketStart: "2026-07-20T20:01:00.000Z", sampleCount: 240, valueSum: 240 }),
    ])

    expect(rows).toHaveLength(1)
    expect(rows[0]?.createRate.map(({ value }) => value)).toEqual([2, 4])
    expect(rows[0]?.allOperationsRate.map(({ value }) => value)).toEqual([2, 4])
  })

  it("does not turn lag-only telemetry into zero event throughput", () => {
    const refreshedAt = "2026-07-22T12:02:00.000Z"
    const rows = collectionMetricRows(
      [
        {
          environment: "dev",
          bucketStart: "2026-07-22T12:01:00.000Z",
          metricName: "socialwire.ingestion.commit_lag_seconds",
          dimensions: { collection: "site.standard.document", ingestion_mode: "live" },
          sampleCount: 1,
          valueSum: 2,
          valueMax: 2,
        },
      ],
      refreshedAt,
    )

    expect(rows[0]?.allOperationsRate.at(-1)?.value).toBeNull()
    expect(rows[0]?.averageLagSeconds.at(-1)?.value).toBe(2)
  })

  it("does not infer zero failures without a result counter observation", () => {
    const rows = collectionMetricRows([
      rollup(),
      rollup({
        metricName: "socialwire.ingestion.results_total",
        dimensions: {
          collection: "site.standard.document",
          operation: "create",
          result: "error",
          ingestion_mode: "live",
        },
        sampleCount: 6,
        valueSum: 6,
      }),
      rollup({ bucketStart: "2026-07-20T20:01:00.000Z", sampleCount: 240, valueSum: 240 }),
    ])

    expect(rows[0]?.failedRate.map(({ value }) => value)).toEqual([0.1, null])
    expect(latestMetricValue(rows[0]!.failedRate)).toBe(0.1)
  })

  it("excludes reconciliation metrics from the live ingestion trend", () => {
    const rows = collectionMetricRows([
      rollup({ dimensions: { collection: "site.standard.document", operation: "create", ingestion_mode: "backfill" } }),
    ])

    expect(rows).toEqual([])
  })

  it("represents missing telemetry buckets as gaps instead of connecting invented values", () => {
    const rows = collectionMetricRows(
      [rollup({ bucketStart: "2026-07-20T19:58:00.000Z" })],
      "2026-07-20T20:01:30.000Z",
    )

    expect(rows[0]?.createRate.slice(-3).map(({ value }) => value)).toEqual([2, null, null])
    expect(currentMetricValue(rows[0]!.createRate)).toBeNull()
    expect(latestMetricValue(rows[0]!.createRate)).toBe(2)
  })

  it("anchors visible buckets to metric evidence time when the overview was fetched in another minute", () => {
    const overviewRefreshedAt = "2026-07-22T12:14:59.000Z"
    const metricsGeneratedAt = "2026-07-22T12:15:01.000Z"
    const windowReference = metricWindowReference(overviewRefreshedAt, {
      source: "operations_metric_rollups",
      accuracy: "exact",
      generatedAt: metricsGeneratedAt,
      ageSeconds: 0,
      validUntil: "2026-07-22T12:16:15.000Z",
    })
    const rows = collectionMetricRows(
      [rollup({ bucketStart: "2026-07-22T12:14:00.000Z" })],
      windowReference,
    )

    expect(windowReference).toBe(metricsGeneratedAt)
    expect(rows[0]?.createRate.at(-1)?.timestamp).toBe(Date.parse("2026-07-22T12:14:00.000Z"))
    expect(rows[0]?.createRate.at(-1)?.value).toBe(2)
  })

  it("keeps the monitored lexicon inventory visible and stable when telemetry is missing", () => {
    const rows = collectionMetricRows(
      [rollup({ dimensions: { collection: "site.standard.entry", operation: "create", ingestion_mode: "live" } })],
      "2026-07-20T20:02:00.000Z",
      MONITORED_COLLECTIONS,
    )

    expect(rows.map((row) => row.collection)).toEqual([...MONITORED_COLLECTIONS])
    expect(rows[0]?.allOperationsRate.every(({ value }) => value === null)).toBe(true)
    expect(latestMetricValue(rows[1]!.allOperationsRate)).toBe(2)
  })

  it("rejects negative metric rollups at the display boundary", () => {
    const rows = collectionMetricRows([rollup({ valueSum: -120 })])

    expect(rows[0]?.createRate).toEqual([])
    expect(latestMetricValue(rows[0]!.createRate)).toBeNull()
  })

  it("distinguishes missing sample evidence from an observed zero", () => {
    const collection = "site.standard.document"

    expect(metricSampleCount([], collection, "socialwire.ingestion.events_total")).toBeUndefined()
    expect(
      metricSampleCount(
        [rollup({ sampleCount: 0, valueSum: 0 })],
        collection,
        "socialwire.ingestion.events_total",
      ),
    ).toBe(0)
  })
})
