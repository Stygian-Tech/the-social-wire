import { expect, test } from "bun:test"
import { formatUserCountDate, userCountTrends } from "@/lib/user-count-trends"
import type { ViewerCounts } from "@/lib/operations-types"

const observation = (observedAt: string, knownViewers = 10): ViewerCounts => ({
  observedAt, knownViewers, activeViewers30d: 8, activeViewers7d: 4,
})
const reference = "2026-09-07T12:00:00Z"

test("aligns the last 90 UTC dates and leaves missing days empty", () => {
  const points = userCountTrends([observation("2026-09-05T15:00:00Z")], reference)
  expect(points).toHaveLength(90)
  expect(new Date(points[0].timestamp).toISOString()).toBe("2026-06-10T00:00:00.000Z")
  expect(points.at(-3)).toEqual({ timestamp: Date.parse("2026-09-05"), known: 10, mau: 8, wau: 4 })
  expect(points.at(-2)).toEqual({ timestamp: Date.parse("2026-09-06"), known: null, mau: null, wau: null })
})

test("takes the latest actual observation for each UTC day without summing counts", () => {
  const points = userCountTrends([
    observation("2026-09-07T11:00:00Z", 12),
    observation("2026-09-07T01:00:00Z", 10),
    observation("2026-09-06T23:00:00-02:00", 11),
  ], reference)
  expect(points.at(-1)?.known).toBe(12)
})

test("excludes old, invalid and future observations without making up history", () => {
  const points = userCountTrends([
    observation("2026-06-09T23:59:59Z"),
    observation("invalid"),
    observation("2026-09-07T12:01:00Z"),
  ], reference)
  expect(points.every((point) => point.known === null)).toBe(true)
  expect(userCountTrends([], "invalid")).toEqual([])
})

test("retains zero counts and rejects invalid values independently", () => {
  const points = userCountTrends([{
    ...observation(reference, 0), activeViewers30d: Number.NaN, activeViewers7d: -1,
  }], reference)
  expect(points.at(-1)).toEqual({ timestamp: Date.parse("2026-09-07"), known: 0, mau: null, wau: null })
  expect(formatUserCountDate(Date.parse("2026-09-07"))).toContain("7")
})
