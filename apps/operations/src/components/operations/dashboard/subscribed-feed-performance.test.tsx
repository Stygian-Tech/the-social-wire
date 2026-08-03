import { describe, expect, it } from "bun:test"
import { render, screen } from "@testing-library/react"

import { SubscribedFeedPerformance } from "@/components/operations/dashboard/subscribed-feed-performance"
import type { MetricRollup } from "@/lib/operations-types"

const queryRollup: MetricRollup = {
  environment: "dev",
  bucketStart: "2026-07-30T02:00:00.000Z",
  metricName: "socialwire.appview.feed.query_duration_seconds",
  dimensions: { feed_kind: "subscribed", page_kind: "first_page" },
  sampleCount: 2,
  valueSum: 0.3,
  valueMin: 0.1,
  valueMax: 0.2,
}

describe("SubscribedFeedPerformance", () => {
  it("renders observed first-page performance without inventing percentiles", () => {
    render(<SubscribedFeedPerformance metricRollups={[queryRollup]} />)

    expect(screen.getByText("Subscribed Feed Performance")).toBeTruthy()
    expect(screen.getByText("First Page")).toBeTruthy()
    expect(screen.getByText("150 ms")).toBeTruthy()
    expect(screen.getByText("200 ms")).toBeTruthy()
    expect(screen.getByText(/not percentiles/i)).toBeTruthy()
  })

  it("renders an explicit empty-evidence state", () => {
    render(<SubscribedFeedPerformance metricRollups={[]} />)
    expect(screen.getByText(/No Subscribed-feed performance samples/i)).toBeTruthy()
  })
})
