import { describe, expect, it } from "bun:test"

import { subscribedFeedPerformanceRows } from "@/lib/subscribed-feed-metrics"
import type { MetricRollup } from "@/lib/operations-types"

function rollup(
  metricName: string,
  pageKind: string,
  sampleCount: number,
  valueSum: number,
  valueMax?: number,
): MetricRollup {
  return {
    environment: "dev",
    bucketStart: "2026-07-30T02:00:00.000Z",
    metricName,
    dimensions: { feed_kind: "subscribed", page_kind: pageKind },
    sampleCount,
    valueSum,
    valueMin: 0,
    valueMax,
  }
}

describe("subscribedFeedPerformanceRows", () => {
  it("summarizes retained rollups by first-page and pagination requests", () => {
    const rows = subscribedFeedPerformanceRows([
      rollup("socialwire.appview.feed.query_duration_seconds", "first_page", 2, 0.3, 0.2),
      rollup("socialwire.appview.feed.rows_scanned", "first_page", 2, 400, 200),
      rollup("socialwire.appview.feed.rows_returned", "first_page", 2, 100, 50),
      rollup("socialwire.appview.feed.payload_bytes", "first_page", 2, 36_000, 18_500),
      rollup("socialwire.appview.feed.duplicates_suppressed", "first_page", 2, 3, 2),
      rollup("socialwire.appview.feed.query_duration_seconds", "pagination", 1, 0.08, 0.08),
    ])

    expect(rows).toHaveLength(2)
    expect(rows[0]).toMatchObject({
      pageKind: "first_page",
      requestSamples: 2,
      averageQueryMilliseconds: 150,
      maximumQueryMilliseconds: 200,
      averageRowsScanned: 200,
      averageRowsReturned: 50,
      scanYieldRatio: 0.25,
      averagePayloadBytes: 18_000,
      duplicatesSuppressed: 3,
    })
    expect(rows[1]).toMatchObject({
      pageKind: "pagination",
      requestSamples: 1,
      averageQueryMilliseconds: 80,
    })
  })

  it("ignores other feed kinds and invalid negative samples", () => {
    const otherFeed = rollup(
      "socialwire.appview.feed.query_duration_seconds",
      "first_page",
      1,
      0.1,
    )
    otherFeed.dimensions.feed_kind = "following"

    expect(subscribedFeedPerformanceRows([
      otherFeed,
      rollup("socialwire.appview.feed.query_duration_seconds", "first_page", 1, -1),
    ])).toEqual([])
  })
})
