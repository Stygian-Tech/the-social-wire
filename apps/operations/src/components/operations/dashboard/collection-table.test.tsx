import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { CollectionTable } from "@/components/operations/dashboard/collection-table"
import { MONITORED_COLLECTIONS } from "@/lib/collection-metrics"
import type { EvidenceEnvelope, MetricRollup } from "@/lib/operations-types"

afterEach(cleanup)

const bucketStart = "2026-07-22T12:14:00.000Z"
const evidence: EvidenceEnvelope = {
  source: "operations_metric_rollups",
  accuracy: "exact",
  generatedAt: "2026-07-22T12:15:05.000Z",
  indexedThrough: "2026-07-22T12:15:00.000Z",
  ageSeconds: 5,
  validUntil: "2026-07-22T12:16:15.000Z",
  coverage: 1,
  lastSuccessfulAt: "2026-07-22T12:15:00.000Z",
}

function rollup(metricName: string, result?: string): MetricRollup {
  return {
    environment: "dev",
    bucketStart,
    metricName,
    dimensions: {
      collection: "site.standard.document",
      ingestion_mode: "live",
      operation: "create",
      ...(result ? { result } : {}),
    },
    sampleCount: 60,
    valueSum: 60,
    valueMin: 1,
    valueMax: 1,
  }
}

describe("CollectionTable", () => {
  it("distinguishes indexed throughput from failed-event rate", () => {
    render(
      <CollectionTable
        metricRollups={[
          rollup("socialwire.ingestion.events_total"),
          rollup("socialwire.ingestion.results_total", "error"),
        ]}
        refreshedAt={evidence.generatedAt}
        referenceTime={evidence.generatedAt}
        evidence={evidence}
      />,
    )

    expect(screen.getByText("1 failed events/sec")).toBeTruthy()
    expect(screen.getAllByText(/Source: AppView Worker indexed-mutation rollups/)).toHaveLength(
      MONITORED_COLLECTIONS.length,
    )
    for (const collection of MONITORED_COLLECTIONS)
      expect(screen.getByText(collection)).toBeTruthy()
  })
})
