import type { MetricRollup } from "@/lib/operations-types"

const QUERY_DURATION = "socialwire.appview.feed.query_duration_seconds"
const ROWS_SCANNED = "socialwire.appview.feed.rows_scanned"
const ROWS_RETURNED = "socialwire.appview.feed.rows_returned"
const DUPLICATES_SUPPRESSED = "socialwire.appview.feed.duplicates_suppressed"
const PAYLOAD_BYTES = "socialwire.appview.feed.payload_bytes"

export type SubscribedFeedPageKind = "first_page" | "pagination"

export type SubscribedFeedPerformanceRow = {
  pageKind: SubscribedFeedPageKind
  requestSamples: number
  averageQueryMilliseconds: number | null
  maximumQueryMilliseconds: number | null
  averageRowsScanned: number | null
  averageRowsReturned: number | null
  scanYieldRatio: number | null
  averagePayloadBytes: number | null
  duplicatesSuppressed: number
}

export type SubscribedFeedTrendPoint = {
  timestamp: number
  firstPageAverageQueryMilliseconds: number | null
  firstPageMaximumQueryMilliseconds: number | null
  paginationAverageQueryMilliseconds: number | null
  paginationMaximumQueryMilliseconds: number | null
  firstPageAverageRowsScanned: number | null
  firstPageAverageRowsReturned: number | null
  paginationAverageRowsScanned: number | null
  paginationAverageRowsReturned: number | null
  firstPageAveragePayloadBytes: number | null
  paginationAveragePayloadBytes: number | null
  firstPageDuplicatesSuppressed: number | null
  paginationDuplicatesSuppressed: number | null
}

type MetricAggregate = {
  count: number
  sum: number
  maximum: number | null
}

function emptyAggregate(): MetricAggregate {
  return { count: 0, sum: 0, maximum: null }
}

function append(aggregate: MetricAggregate, rollup: MetricRollup) {
  if (
    !Number.isSafeInteger(rollup.sampleCount) ||
    rollup.sampleCount < 0 ||
    !Number.isFinite(rollup.valueSum) ||
    rollup.valueSum < 0
  )
    return

  aggregate.count += rollup.sampleCount
  aggregate.sum += rollup.valueSum
  if (rollup.valueMax !== undefined && Number.isFinite(rollup.valueMax) && rollup.valueMax >= 0)
    aggregate.maximum = Math.max(aggregate.maximum ?? 0, rollup.valueMax)
}

function average(aggregate: MetricAggregate, multiplier = 1) {
  return aggregate.count > 0 ? (aggregate.sum / aggregate.count) * multiplier : null
}

export function subscribedFeedPerformanceRows(
  rollups: MetricRollup[],
): SubscribedFeedPerformanceRow[] {
  return (["first_page", "pagination"] as const).flatMap((pageKind) => {
    const metrics = new Map<string, MetricAggregate>()
    for (const rollup of rollups) {
      if (
        rollup.dimensions.feed_kind !== "subscribed" ||
        rollup.dimensions.page_kind !== pageKind
      )
        continue
      const aggregate = metrics.get(rollup.metricName) ?? emptyAggregate()
      append(aggregate, rollup)
      metrics.set(rollup.metricName, aggregate)
    }

    const query = metrics.get(QUERY_DURATION) ?? emptyAggregate()
    if (query.count === 0) return []
    const scanned = metrics.get(ROWS_SCANNED) ?? emptyAggregate()
    const returned = metrics.get(ROWS_RETURNED) ?? emptyAggregate()
    const duplicates = metrics.get(DUPLICATES_SUPPRESSED) ?? emptyAggregate()
    const payload = metrics.get(PAYLOAD_BYTES) ?? emptyAggregate()

    return [{
      pageKind,
      requestSamples: query.count,
      averageQueryMilliseconds: average(query, 1_000),
      maximumQueryMilliseconds:
        query.maximum === null ? null : query.maximum * 1_000,
      averageRowsScanned: average(scanned),
      averageRowsReturned: average(returned),
      scanYieldRatio: scanned.sum > 0 ? returned.sum / scanned.sum : null,
      averagePayloadBytes: average(payload),
      duplicatesSuppressed: duplicates.sum,
    }]
  })
}

export function subscribedFeedPerformanceTrends(rollups: MetricRollup[]): SubscribedFeedTrendPoint[] {
  const relevant = rollups.filter(
    (rollup) =>
      rollup.dimensions.feed_kind === "subscribed" &&
      (rollup.dimensions.page_kind === "first_page" || rollup.dimensions.page_kind === "pagination") &&
      [QUERY_DURATION, ROWS_SCANNED, ROWS_RETURNED, DUPLICATES_SUPPRESSED, PAYLOAD_BYTES]
        .includes(rollup.metricName),
  )
  const timestamps = relevant
    .map(({ bucketStart }) => new Date(bucketStart).getTime())
    .filter(Number.isFinite)
  if (timestamps.length === 0) return []
  const start = Math.min(...timestamps)
  const end = Math.max(...timestamps)
  const buckets = Array.from({ length: Math.floor((end - start) / 60_000) + 1 }, (_, index) => start + index * 60_000)
  const rollupsByTimestamp = new Map<number, MetricRollup[]>()
  for (const rollup of relevant) {
    const timestamp = new Date(rollup.bucketStart).getTime()
    const bucket = rollupsByTimestamp.get(timestamp) ?? []
    bucket.push(rollup)
    rollupsByTimestamp.set(timestamp, bucket)
  }

  return buckets.map((timestamp) => {
    const point: Record<string, number | null> = { timestamp }
    const bucket = rollupsByTimestamp.get(timestamp) ?? []
    for (const pageKind of ["first_page", "pagination"] as const) {
      const metrics = new Map<string, MetricAggregate>()
      for (const rollup of bucket) {
        if (rollup.dimensions.page_kind !== pageKind) continue
        const aggregate = metrics.get(rollup.metricName) ?? emptyAggregate()
        append(aggregate, rollup)
        metrics.set(rollup.metricName, aggregate)
      }
      const prefix = pageKind === "first_page" ? "firstPage" : "pagination"
      const query = metrics.get(QUERY_DURATION) ?? emptyAggregate()
      const scanned = metrics.get(ROWS_SCANNED) ?? emptyAggregate()
      const returned = metrics.get(ROWS_RETURNED) ?? emptyAggregate()
      const payload = metrics.get(PAYLOAD_BYTES) ?? emptyAggregate()
      const duplicates = metrics.get(DUPLICATES_SUPPRESSED) ?? emptyAggregate()
      point[`${prefix}AverageQueryMilliseconds`] = average(query, 1_000)
      point[`${prefix}MaximumQueryMilliseconds`] = query.maximum === null ? null : query.maximum * 1_000
      point[`${prefix}AverageRowsScanned`] = average(scanned)
      point[`${prefix}AverageRowsReturned`] = average(returned)
      point[`${prefix}AveragePayloadBytes`] = average(payload)
      point[`${prefix}DuplicatesSuppressed`] = duplicates.count > 0 ? duplicates.sum : null
    }
    return point as SubscribedFeedTrendPoint
  })
}
